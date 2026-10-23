"""Camera status as sensors (battery, battery temperature, charging, Wi-Fi signal, event counts) from the shared
settings read, and the HomeBase's storage (drive used and free, health, temperature, days kept). Entity names
follow eufy_security's where it had one (`*_battery_percentage`, `*_charging_status`)."""

from __future__ import annotations

from datetime import timedelta
import logging

import aiohttp

from homeassistant.components.sensor import SensorDeviceClass, SensorEntity, SensorStateClass
from homeassistant.const import PERCENTAGE, SIGNAL_STRENGTH_DECIBELS_MILLIWATT, UnitOfInformation, UnitOfTemperature
from homeassistant.core import HomeAssistant
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.event import async_track_time_interval

from . import DOMAIN, object_id
from .settings import CameraSettings, camera_settings

_LOGGER = logging.getLogger(__name__)
STORAGE_REFRESH = timedelta(minutes=30)

# (setting id, entity suffix, label, unit, device class)
CAMERA_SENSORS = [
    ("battery", "battery_percentage", "Battery", PERCENTAGE, SensorDeviceClass.BATTERY),
    ("batteryTemperature", "battery_temperature", "Battery temperature", UnitOfTemperature.CELSIUS, SensorDeviceClass.TEMPERATURE),
    ("wifiRssi", "wifi_signal", "Wi-Fi signal", SIGNAL_STRENGTH_DECIBELS_MILLIWATT, SensorDeviceClass.SIGNAL_STRENGTH),
]
CHARGING = {0: "Not charging", 1: "Charging"}


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    entities: list[SensorEntity] = []
    session = async_get_clientsession(hass)
    for camera in hass.data[DOMAIN]["cameras"]:
        try:
            async with session.get(f"{hass.data[DOMAIN]['url']}/api/cameras/{camera['channel']}/settings/catalog",
                                   timeout=aiohttp.ClientTimeout(total=15)) as resp:
                readings = set((await resp.json()).get("readings", []))
        except (aiohttp.ClientError, ValueError):
            continue
        settings = camera_settings(hass, camera)
        # Only what this model reports: no battery sensors for plugged-in indoor cameras.
        cam = [CameraSensor(hass, camera, settings, *spec) for spec in CAMERA_SENSORS if spec[0] in readings]
        if "chargingStatus" in readings:
            cam.append(ChargingSensor(hass, camera, settings))
        cam.append(EventsSensor(hass, camera, settings))
        settings.entities += cam
        entities += cam
    storage = HomeBaseStorage(hass)
    storage_entities = [StorageSensor(storage, *spec) for spec in STORAGE_SENSORS]
    storage.entities = storage_entities
    entities += storage_entities
    async_add_entities(entities)
    hass.async_create_task(storage.refresh())
    async_track_time_interval(hass, storage.refresh_tick, STORAGE_REFRESH)


class _CameraEntity(SensorEntity):
    _attr_should_poll = False

    def __init__(self, hass: HomeAssistant, camera: dict, settings: CameraSettings, key: str, suffix: str, label: str) -> None:
        self._settings = settings
        self._key = key
        self._attr_name = f"{camera['name']} {label}"
        self._attr_unique_id = f"eufynized_{camera['serial']}_{suffix}"
        self.entity_id = f"sensor.{object_id(hass, camera)}_{suffix}"

    @property
    def _value(self):
        return (self._settings.values or {}).get(self._key)

    @property
    def available(self) -> bool:
        return self._value is not None


class CameraSensor(_CameraEntity):
    _attr_state_class = SensorStateClass.MEASUREMENT

    def __init__(self, hass, camera, settings, key, suffix, label, unit, device_class) -> None:
        super().__init__(hass, camera, settings, key, suffix, label)
        self._attr_native_unit_of_measurement = unit
        self._attr_device_class = device_class

    @property
    def available(self) -> bool:
        # The HomeBase reports -100 for a camera it can't hear (unplugged or out of range).
        return isinstance(self._value, (int, float)) and not (self._key == "wifiRssi" and self._value <= -100)

    @property
    def native_value(self):
        return self._value

    @property
    def extra_state_attributes(self) -> dict | None:
        info = self._settings.info
        if self._key == "battery" and info.get("batteryHistory"):
            return {"trend_per_day": info.get("batteryTrendPerDay"),
                    "history": [h["percent"] for h in info["batteryHistory"]]}
        if self._key == "wifiRssi" and isinstance(self._value, (int, float)):
            v = self._value
            return {"quality": "Excellent" if v >= -50 else "Good" if v >= -60 else "Fair" if v >= -70 else "Weak"}
        return None


class ChargingSensor(_CameraEntity):
    def __init__(self, hass, camera, settings) -> None:
        super().__init__(hass, camera, settings, "chargingStatus", "charging_status", "Charging")

    @property
    def native_value(self):
        v = self._value
        if not isinstance(v, int):
            return None
        if v in CHARGING:
            return CHARGING[v]
        return "Solar charging" if (self._settings.values or {}).get("powerSource") == 1 else "Charging"

    @property
    def extra_state_attributes(self) -> dict:
        # solar_reading: the camera's unnamed parameter 1309, most likely the solar panel's charging level.
        return {"code": self._value, "solar_reading": self._settings.info.get("solarReading")}


class EventsSensor(_CameraEntity):
    """Lifetime detected events, with recorded events, working days and firmware as attributes."""

    _attr_state_class = SensorStateClass.TOTAL_INCREASING
    _attr_icon = "mdi:motion-sensor"

    def __init__(self, hass, camera, settings) -> None:
        super().__init__(hass, camera, settings, "", "detected_events", "Detected events")

    @property
    def available(self) -> bool:
        return self._settings.info.get("detectedEvents") is not None

    @property
    def native_value(self):
        return self._settings.info.get("detectedEvents")

    @property
    def extra_state_attributes(self) -> dict:
        info = self._settings.info
        return {"recorded_events": info.get("recordedEvents"), "working_days": info.get("workingDays"),
                "firmware": info.get("firmware")}


class HomeBaseStorage:
    def __init__(self, hass: HomeAssistant) -> None:
        self.hass = hass
        self.data: dict | None = None
        self.entities: list[StorageSensor] = []

    async def refresh_tick(self, _now) -> None:
        await self.refresh()

    async def refresh(self) -> None:
        session = async_get_clientsession(self.hass)
        try:
            async with session.get(f"{self.hass.data[DOMAIN]['url']}/api/storage",
                                   timeout=aiohttp.ClientTimeout(total=20)) as resp:
                data = await resp.json()
            self.data = data if "hdd_info" in data or "emmc_info" in data else None
        except (aiohttp.ClientError, ValueError, TimeoutError):
            self.data = None
        for entity in self.entities:
            if entity.hass:
                entity.async_write_ha_state()

    @property
    def drive(self) -> dict | None:
        d = (self.data or {}).get("hdd_info") or {}
        return d if d.get("video_size") else (self.data or {}).get("emmc_info")


def _used_percent(s: HomeBaseStorage):
    d = s.drive
    return round(100 * d["video_used"] / d["video_size"], 1) if d and d.get("video_size") else None


def _free_gb(s: HomeBaseStorage):
    d = s.drive
    return round((d["video_size"] - d["video_used"]) / 1024, 1) if d and d.get("video_size") else None


# (suffix, label, unit, device class, icon, value)
STORAGE_SENSORS = [
    ("storage_used", "Storage used", PERCENTAGE, None, "mdi:harddisk", _used_percent),
    ("storage_free", "Storage free", UnitOfInformation.GIGABYTES, SensorDeviceClass.DATA_SIZE, "mdi:harddisk", _free_gb),
    ("drive_temperature", "Drive temperature", UnitOfTemperature.CELSIUS, SensorDeviceClass.TEMPERATURE, None,
     lambda s: (s.drive or {}).get("cur_temperate")),
    ("drive_health", "Drive health", None, None, "mdi:harddisk-plus",
     lambda s: None if s.drive is None else ("Healthy" if s.drive.get("health") == 0 else f"Problem ({s.drive.get('health')})")),
    ("days_recorded", "Days of recordings", "d", None, "mdi:calendar-range", lambda s: (s.data or {}).get("storage_days")),
]


class StorageSensor(SensorEntity):
    _attr_should_poll = False

    def __init__(self, storage: HomeBaseStorage, suffix, label, unit, device_class, icon, value) -> None:
        self._storage = storage
        self._value = value
        alarm = storage.hass.data[DOMAIN]["config"].get("alarm_entity_name") or "eufynized_homebase"
        self._attr_name = f"HomeBase {label}"
        self._attr_unique_id = f"eufynized_homebase_{suffix}"
        self.entity_id = f"sensor.{alarm}_{suffix}"
        self._attr_native_unit_of_measurement = unit
        self._attr_device_class = device_class
        if icon:
            self._attr_icon = icon
        if unit in (PERCENTAGE, UnitOfTemperature.CELSIUS, UnitOfInformation.GIGABYTES):
            self._attr_state_class = SensorStateClass.MEASUREMENT

    @property
    def available(self) -> bool:
        return self.native_value is not None

    @property
    def native_value(self):
        return self._value(self._storage) if self._storage.data else None

    @property
    def extra_state_attributes(self) -> dict | None:
        if self._attr_unique_id.endswith("storage_used") and self._storage.drive:
            d = self._storage.drive
            return {"drive": d.get("device_module"), "events_stored": (self._storage.data or {}).get("storage_events"),
                    "video_used_gb": round(d["video_used"] / 1024, 1), "video_total_gb": round(d["video_size"] / 1024, 1)}
        return None
