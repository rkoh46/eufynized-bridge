"""The latest event's picture per camera: a full-resolution frame grabbed from the camera when the HomeBase
announces the event (like the Mac app's banners), much sharper than the HomeBase's own event thumbnail."""

from __future__ import annotations

import asyncio

import aiohttp

from homeassistant.components.image import ImageEntity
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.util import dt as dt_util

from . import DOMAIN, SIGNAL_EVENT, object_id


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    async_add_entities(EventImage(hass, camera) for camera in hass.data[DOMAIN]["cameras"])


class EventImage(ImageEntity):
    _attr_should_poll = False
    _attr_content_type = "image/jpeg"

    def __init__(self, hass: HomeAssistant, camera: dict) -> None:
        super().__init__(hass)
        self._camera = camera
        self._base = hass.data[DOMAIN]["url"]
        self._attr_name = f"{camera['name']} Event image"
        self._attr_unique_id = f"eufynized_{camera['serial']}_event_image"
        self.entity_id = f"image.{object_id(hass, camera)}_event_image"
        self._jpeg: bytes | None = None
        self._busy = False
        # Set while no capture is running. A capture takes 10–15 s (the camera wakes, then steps up to full
        # resolution); anyone asking for the picture meanwhile waits for it instead of getting an older one.
        self._ready = asyncio.Event()
        self._ready.set()

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(async_dispatcher_connect(self.hass, SIGNAL_EVENT, self._on_event))

    @callback
    def _on_event(self, event: dict) -> None:
        if event.get("channel") != self._camera["channel"] or self._busy:
            return
        self._busy = True
        self._ready.clear()
        self.hass.async_create_task(self._capture())

    async def _capture(self) -> None:
        try:
            session = async_get_clientsession(self.hass)
            async with session.get(f"{self._base}/api/cameras/{self._camera['channel']}/snapshot.jpg",
                                   params={"full": "1", "settle": "0"}, timeout=aiohttp.ClientTimeout(total=45)) as resp:
                if resp.status == 200:
                    self._jpeg = await resp.read()
                    self._attr_image_last_updated = dt_util.utcnow()
                    self.async_write_ha_state()
        except (aiohttp.ClientError, TimeoutError):
            pass
        finally:
            self._busy = False
            self._ready.set()

    async def async_image(self) -> bytes | None:
        # An event's picture is being captured: wait for it (an automation reading the picture right after the
        # event must analyze this event, not the previous one).
        try:
            await asyncio.wait_for(self._ready.wait(), timeout=30)
        except TimeoutError:
            pass
        if self._jpeg is None:
            # Before the first event: the camera's latest picture.
            session = async_get_clientsession(self.hass)
            try:
                async with session.get(f"{self._base}/api/cameras/{self._camera['channel']}/snapshot.jpg",
                                       params={"maxAge": "1e12"}, timeout=aiohttp.ClientTimeout(total=30)) as resp:
                    if resp.status == 200:
                        return await resp.read()
            except aiohttp.ClientError:
                return None
        return self._jpeg
