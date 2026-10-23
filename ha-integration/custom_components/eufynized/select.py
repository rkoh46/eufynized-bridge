"""Pickers per camera: the camera's notification style (its own setting, as in the eufy app), and snooze (mutes
the camera's alerts for a while, in Eufynized and on the HomeBase). Automations can check
`is_state('select.<camera>_snooze', 'Off')` before sending their own alerts."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import logging

import aiohttp

from homeassistant.components.select import SelectEntity
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.event import async_track_point_in_utc_time

from . import DOMAIN, object_id
from .settings import CameraSettings, camera_settings

_LOGGER = logging.getLogger(__name__)

SNOOZE = {"Off": 0, "30 minutes": 30, "1 hour": 60, "2 hours": 120, "8 hours": 480}
# Camera settings with a list of choices → a select entity: setting id → (entity suffix, name).
CHOICES = {
    "notificationType": ("notification_style", "Notification style"),
    "powerSourceMode": ("power_source", "Power source"),            # eufyCam 3 family: Battery / Direct power
    "continuousRecordingType": ("continuous_recording_mode", "Continuous recording mode"),
}


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    entities: list[SelectEntity] = []
    session = async_get_clientsession(hass)
    for camera in hass.data[DOMAIN]["cameras"]:
        entities.append(SnoozeSelect(hass, camera))
        try:
            async with session.get(f"{hass.data[DOMAIN]['url']}/api/cameras/{camera['channel']}/settings/catalog",
                                   timeout=aiohttp.ClientTimeout(total=15)) as resp:
                choices = (await resp.json()).get("choices", [])
        except (aiohttp.ClientError, ValueError):
            continue
        for setting_id, (suffix, label) in CHOICES.items():
            if setting_id in choices:
                settings = camera_settings(hass, camera)
                select = ChoiceSelect(hass, camera, settings, setting_id, suffix, label)
                settings.entities.append(select)
                entities.append(select)
    async_add_entities(entities)


class ChoiceSelect(SelectEntity):
    _attr_should_poll = False

    def __init__(self, hass: HomeAssistant, camera: dict, settings: CameraSettings, setting_id: str, suffix: str, label: str) -> None:
        self._settings = settings
        self._id = setting_id
        self._attr_name = f"{camera['name']} {label}"
        self._attr_unique_id = f"eufynized_{camera['serial']}_{suffix}"
        self._attr_icon = {"notificationType": "mdi:bell-cog", "powerSourceMode": "mdi:power-plug",
                           "continuousRecordingType": "mdi:record-rec"}.get(setting_id)
        self.entity_id = f"select.{object_id(hass, camera)}_{suffix}"

    @property
    def _setting(self) -> dict | None:
        s = self._settings.settings.get(self._id)
        return s if s and s.get("options") and self._settings.values is not None else None

    @property
    def available(self) -> bool:
        return self._setting is not None

    @property
    def options(self) -> list[str]:
        return [o["label"] for o in (self._setting or {}).get("options", [])]

    @property
    def current_option(self) -> str | None:
        s = self._setting
        return next((o["label"] for o in s["options"] if o["value"] == s.get("value")), None) if s else None

    async def async_select_option(self, option: str) -> None:
        s = self._setting
        value = next((o["value"] for o in (s or {}).get("options", []) if o["label"] == option), None)
        if value is None:
            raise HomeAssistantError(f"Unknown option {option}")
        await self._settings.write(self._id, value)


class SnoozeSelect(SelectEntity):
    _attr_icon = "mdi:bell-sleep"
    _attr_options = list(SNOOZE)
    _attr_should_poll = False

    def __init__(self, hass: HomeAssistant, camera: dict) -> None:
        self._camera = camera
        self._url = f"{hass.data[DOMAIN]['url']}/api/cameras/{camera['channel']}/snooze"
        self._until: datetime | None = None
        self._choice = "Off"
        self._cancel = None
        self._attr_name = f"{camera['name']} Snooze"
        self._attr_unique_id = f"eufynized_{camera['serial']}_snooze"
        self.entity_id = f"select.{object_id(hass, camera)}_snooze"

    async def async_added_to_hass(self) -> None:
        # Pick up a snooze that's still running (set before a restart, or from the Security Camera page).
        try:
            async with async_get_clientsession(self.hass).get(self._url, timeout=aiohttp.ClientTimeout(total=10)) as resp:
                until = (await resp.json()).get("snoozedUntil")
        except (aiohttp.ClientError, ValueError, TimeoutError):
            until = None
        if until:
            minutes = (until - datetime.now(timezone.utc).timestamp()) / 60
            self._choice = min((k for k, v in SNOOZE.items() if v), key=lambda k: abs(SNOOZE[k] - minutes))
            self._schedule_end(datetime.fromtimestamp(until, timezone.utc))

    @property
    def current_option(self) -> str:
        return self._choice

    @property
    def extra_state_attributes(self) -> dict:
        return {"until": self._until.isoformat() if self._until else None}

    def _schedule_end(self, until: datetime | None) -> None:
        if self._cancel:
            self._cancel()
            self._cancel = None
        self._until = until
        if until:
            self._cancel = async_track_point_in_utc_time(self.hass, self._ended, until)

    async def _ended(self, _now) -> None:
        self._cancel = None
        self._until = None
        self._choice = "Off"
        self.async_write_ha_state()

    async def async_select_option(self, option: str) -> None:
        minutes = SNOOZE[option]
        try:
            async with async_get_clientsession(self.hass).post(self._url, json={"minutes": minutes},
                                                               timeout=aiohttp.ClientTimeout(total=20)) as resp:
                data = await resp.json()
        except (aiohttp.ClientError, ValueError, TimeoutError) as err:
            raise HomeAssistantError(f"{self._camera['name']}: the Eufynized bridge didn't answer ({err})") from err
        until = data.get("snoozedUntil")
        self._choice = option if until else "Off"
        self._schedule_end(datetime.fromtimestamp(until, timezone.utc) if until else None)
        self.async_write_ha_state()
