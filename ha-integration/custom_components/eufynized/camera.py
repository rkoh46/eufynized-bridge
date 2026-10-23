"""Eufynized cameras: the latest picture, and a stream (go2rtc's local RTSP, fed by the bridge) for HA's own
camera cards. The bridge only talks to a camera while something is watching."""

from __future__ import annotations

import aiohttp

from homeassistant.components.camera import Camera, CameraEntityFeature
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from . import DOMAIN, object_id

RTSP_PORT = 28554


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    async_add_entities(EufynizedCamera(hass, camera) for camera in hass.data[DOMAIN]["cameras"])


class EufynizedCamera(Camera):
    _attr_has_entity_name = False
    _attr_supported_features = CameraEntityFeature.STREAM

    def __init__(self, hass: HomeAssistant, camera: dict) -> None:
        super().__init__()
        self._camera = camera
        self._base = hass.data[DOMAIN]["url"]
        self._attr_name = camera["name"]
        self._attr_unique_id = f"eufynized_{camera['serial']}_camera"
        self._attr_brand = "eufy"
        self._attr_model = camera.get("model")
        self.entity_id = f"camera.{object_id(hass, camera)}"

    async def async_camera_image(self, width: int | None = None, height: int | None = None) -> bytes | None:
        # A picture up to ten minutes old is fine for a thumbnail. Each refresh opens a session on the HomeBase,
        # which allows only a few at once; a shorter age had seven cameras refreshing together and stalling
        # whatever stream was being watched.
        session = async_get_clientsession(self.hass)
        try:
            async with session.get(f"{self._base}/api/cameras/{self._camera['channel']}/snapshot.jpg",
                                   params={"maxAge": "600"}, timeout=aiohttp.ClientTimeout(total=60)) as resp:
                return await resp.read() if resp.status == 200 else None
        except aiohttp.ClientError:
            return None

    async def stream_source(self) -> str | None:
        return f"rtsp://127.0.0.1:{RTSP_PORT}/ch{self._camera['channel']}"
