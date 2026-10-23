"""One camera's settings and status, read from the HomeBase through the bridge and shared by that camera's
switches, sensors and pickers: one read every 30 minutes, one camera at a time."""

from __future__ import annotations

from datetime import timedelta
import asyncio

import aiohttp

from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.event import async_track_time_interval

from . import DOMAIN

REFRESH = timedelta(minutes=30)


def camera_settings(hass: HomeAssistant, camera: dict) -> "CameraSettings":
    """The shared reader for a camera, created (and scheduled) on first use."""
    registry = hass.data[DOMAIN].setdefault("camera_settings", {})
    settings = registry.get(camera["channel"])
    if settings is None:
        settings = registry[camera["channel"]] = CameraSettings(hass, camera)
        hass.async_create_task(settings.refresh())
        # A coroutine runs on the event loop; a plain lambda would be called from a worker thread.
        async_track_time_interval(hass, settings.refresh_tick, REFRESH)
    return settings


class CameraSettings:
    def __init__(self, hass: HomeAssistant, camera: dict) -> None:
        self.hass = hass
        self.camera = camera
        self.values: dict | None = None
        self.settings: dict[str, dict] = {}
        self.info: dict = {}
        self.entities: list = []
        self._url = f"{hass.data[DOMAIN]['url']}/api/cameras/{camera['channel']}/settings"

    def _apply(self, data: dict) -> None:
        self.settings = {s["id"]: s for g in data["groups"] for s in g["settings"]}
        self.values = {k: s.get("value") for k, s in self.settings.items()}
        self.info = data.get("info") or self.info

    def _notify(self) -> None:
        for entity in self.entities:
            if entity.hass:
                entity.async_write_ha_state()

    async def refresh_tick(self, _now) -> None:
        await self.refresh()

    async def refresh(self) -> None:
        # One camera at a time: each read opens a HomeBase session, and the HomeBase allows only a few at once.
        lock = self.hass.data[DOMAIN].setdefault("settings_lock", asyncio.Lock())
        async with lock:
            session = async_get_clientsession(self.hass)
            try:
                async with session.get(self._url, timeout=aiohttp.ClientTimeout(total=60)) as resp:
                    data = await resp.json()
                if "groups" in data:
                    self._apply(data)
                else:
                    self.values = None   # offline, asleep or not answering
            except (aiohttp.ClientError, ValueError, TimeoutError):
                self.values = None
        self._notify()

    async def write(self, setting_id: str, value) -> None:
        session = async_get_clientsession(self.hass)
        try:
            async with session.post(self._url, json={"id": setting_id, "value": value},
                                    timeout=aiohttp.ClientTimeout(total=90)) as resp:
                data = await resp.json()
        except (aiohttp.ClientError, ValueError, TimeoutError) as err:
            raise HomeAssistantError(f"{self.camera['name']}: the Eufynized bridge didn't answer ({err})") from err
        if "groups" in data:
            self._apply(data)
        self._notify()
        if data.get("message"):
            raise HomeAssistantError(f"{self.camera['name']}: {data['message']}")
