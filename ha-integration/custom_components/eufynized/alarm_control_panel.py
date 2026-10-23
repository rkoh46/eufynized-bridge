"""The HomeBase's guard mode as an alarm panel: Home, Away, Disarmed (set over the HomeBase's local P2P
protocol, like everything else in Eufynized). The HomeBase only announces changes, so the last known state is
restored after a restart."""

from __future__ import annotations

import aiohttp

from homeassistant.components.alarm_control_panel import (
    AlarmControlPanelEntity,
    AlarmControlPanelEntityFeature,
    AlarmControlPanelState,
)
from homeassistant.core import HomeAssistant, callback
from homeassistant.exceptions import HomeAssistantError
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.restore_state import RestoreEntity

from . import DOMAIN, SIGNAL_GUARD

MODES = {
    0: AlarmControlPanelState.ARMED_AWAY,
    1: AlarmControlPanelState.ARMED_HOME,
    2: AlarmControlPanelState.ARMED_CUSTOM_BYPASS,   # schedule
    3: AlarmControlPanelState.ARMED_CUSTOM_BYPASS,
    4: AlarmControlPanelState.ARMED_CUSTOM_BYPASS,
    5: AlarmControlPanelState.ARMED_CUSTOM_BYPASS,
    6: AlarmControlPanelState.DISARMED,              # off
    47: AlarmControlPanelState.ARMED_CUSTOM_BYPASS,  # geofencing
    63: AlarmControlPanelState.DISARMED,
}
NAMES = {0: "Away", 1: "Home", 2: "Schedule", 3: "Custom 1", 4: "Custom 2", 5: "Custom 3", 6: "Off", 47: "Geofencing",
         63: "Disarmed"}


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    async_add_entities([GuardMode(hass)])


class GuardMode(AlarmControlPanelEntity, RestoreEntity):
    _attr_should_poll = False
    _attr_code_arm_required = False
    _attr_supported_features = AlarmControlPanelEntityFeature.ARM_HOME | AlarmControlPanelEntityFeature.ARM_AWAY

    def __init__(self, hass: HomeAssistant) -> None:
        name = hass.data[DOMAIN]["config"]["alarm_entity_name"]
        self._base = hass.data[DOMAIN]["url"]
        self._attr_name = "HomeBase guard mode"
        self._attr_unique_id = "eufynized_homebase_guard_mode"
        self.entity_id = f"alarm_control_panel.{name}"
        self._mode = hass.data[DOMAIN].get("guard_mode")
        self._attr_alarm_state = MODES.get(self._mode)
        self._info: dict = {}

    async def async_added_to_hass(self) -> None:
        if self._attr_alarm_state is None and (last := await self.async_get_last_state()):
            try:
                self._attr_alarm_state = AlarmControlPanelState(last.state)
            except ValueError:
                pass
        self.async_on_remove(async_dispatcher_connect(self.hass, SIGNAL_GUARD, self._on_mode))
        self.hass.async_create_task(self._load_info())

    async def _load_info(self) -> None:
        # Firmware and the schedule's fallback mode. The schedule's time slots live in the eufy cloud, not the HomeBase.
        try:
            async with async_get_clientsession(self.hass).get(f"{self._base}/api/homebase",
                                                              timeout=aiohttp.ClientTimeout(total=20)) as resp:
                self._info = await resp.json()
        except (aiohttp.ClientError, ValueError, TimeoutError):
            return
        self.async_write_ha_state()

    @property
    def extra_state_attributes(self) -> dict:
        fallback = self._info.get("scheduleFallbackMode")
        return {"mode": NAMES.get(self._mode, self._mode), "firmware": self._info.get("firmware"),
                "schedule_fallback_mode": NAMES.get(fallback, fallback)}

    @callback
    def _on_mode(self, mode) -> None:
        self._mode = mode
        self._attr_alarm_state = MODES.get(mode)
        self.async_write_ha_state()

    async def _set(self, mode: str) -> None:
        session = async_get_clientsession(self.hass)
        try:
            async with session.post(f"{self._base}/api/guard", json={"mode": mode},
                                    timeout=aiohttp.ClientTimeout(total=20)) as resp:
                result = await resp.json()
        except aiohttp.ClientError as err:
            raise HomeAssistantError(f"The Eufynized bridge isn't answering: {err}") from err
        if result.get("result") != 0:
            raise HomeAssistantError(f"The HomeBase didn't change mode: {result}")

    async def async_alarm_arm_home(self, code: str | None = None) -> None:
        await self._set("home")

    async def async_alarm_arm_away(self, code: str | None = None) -> None:
        await self._set("away")

    async def async_alarm_disarm(self, code: str | None = None) -> None:
        await self._set("disarmed")
