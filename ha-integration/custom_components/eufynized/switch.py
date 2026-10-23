"""Camera settings as switches (notifications per kind, microphone, night vision, status light, …), with the
names the eufy_security integration used, so scripts like naptime keep working. Written over the HomeBase's
local protocol and read back to confirm, like the Security Camera page's settings. Never the camera's power
switch: that stays in the page, deliberately one step away."""

from __future__ import annotations

import logging

import aiohttp

from homeassistant.components.switch import SwitchEntity
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession

from . import DOMAIN, object_id
from .settings import CameraSettings, camera_settings

_LOGGER = logging.getLogger(__name__)

# Eufynized setting id → the entity name eufy_security used.
NAMES = {
    "notificationCrying": "notification_crying_detected",
    "notificationAllSound": "notification_sound_detected",
    "notificationPerson": "notification_person_detected",
    "notificationPet": "notification_pet_detected",
    "notificationAllOtherMotion": "notification_motion_detected",
    "microphone": "microphone",
    "speaker": "speaker",
    "audioRecording": "record_audio",
    "autoNightvision": "auto_nightvision",
    "statusLed": "status_led",
    "rtspStream": "rtsp_stream",
    "motionDetection": "motion_detection",
    "motionTracking": "motion_tracking",
    "light": "light",
    # What triggers a recording: with "all other motion" off, only people, vehicles (and pets, if on) do: the
    # cameras' equivalent of "record only on AI detection".
    "motionDetectionTypeHuman": "detect_people",
    "motionDetectionTypeVehicle": "detect_vehicles",
    "motionDetectionTypePet": "detect_pets",
    "motionDetectionTypeAllOtherMotions": "detect_all_other_motion",
    "continuousRecording": "continuous_recording",
}


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    base = hass.data[DOMAIN]["url"]
    session = async_get_clientsession(hass)
    entities = []
    for camera in hass.data[DOMAIN]["cameras"]:
        try:
            async with session.get(f"{base}/api/cameras/{camera['channel']}/settings/catalog",
                                   timeout=aiohttp.ClientTimeout(total=15)) as resp:
                toggles = (await resp.json()).get("toggles", [])
        except (aiohttp.ClientError, ValueError):
            continue
        if not any(t["id"] in NAMES for t in toggles):
            continue
        settings = camera_settings(hass, camera)
        cam_entities = [SettingSwitch(hass, camera, settings, t["id"], t["label"]) for t in toggles if t["id"] in NAMES]
        settings.entities += cam_entities
        entities += cam_entities
    async_add_entities(entities)


class SettingSwitch(SwitchEntity):
    _attr_should_poll = False

    def __init__(self, hass: HomeAssistant, camera: dict, settings: CameraSettings, setting_id: str, label: str) -> None:
        self._settings = settings
        self._id = setting_id
        self._attr_name = f"{camera['name']} {label}"
        self._attr_unique_id = f"eufynized_{camera['serial']}_{setting_id}"
        self.entity_id = f"switch.{object_id(hass, camera)}_{NAMES[setting_id]}"

    @property
    def available(self) -> bool:
        return self._settings.values is not None and self._id in self._settings.values

    @property
    def is_on(self) -> bool | None:
        value = (self._settings.values or {}).get(self._id)
        return value if isinstance(value, bool) else None

    async def async_turn_on(self, **kwargs) -> None:
        await self._settings.write(self._id, True)

    async def async_turn_off(self, **kwargs) -> None:
        await self._settings.write(self._id, False)
