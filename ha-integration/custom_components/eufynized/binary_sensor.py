"""Detection sensors per camera: on for a few seconds after each event the HomeBase announces."""

from __future__ import annotations

from homeassistant.components.binary_sensor import BinarySensorDeviceClass, BinarySensorEntity
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers.dispatcher import async_dispatcher_connect
from homeassistant.helpers.event import async_call_later

from . import DOMAIN, SIGNAL_EVENT, object_id

ON_SECONDS = 15

# The HomeBase's event types per sensor. A person, pet or vehicle is motion too.
KINDS = {
    "motion": ({3101, 3102, 3111, 3112, 3106, 3107, 3108, 3109, 3110}, BinarySensorDeviceClass.MOTION, "Motion"),
    "person": ({3102, 3111, 3112}, BinarySensorDeviceClass.OCCUPANCY, "Person"),
    "pet": ({3106, 3108, 3109, 3110}, BinarySensorDeviceClass.MOTION, "Pet"),
    "vehicle": ({3107}, BinarySensorDeviceClass.MOTION, "Vehicle"),
    "crying": ({3104}, BinarySensorDeviceClass.SOUND, "Crying"),
    "sound": ({3104, 3105}, BinarySensorDeviceClass.SOUND, "Sound"),
    "ring": ({3103}, BinarySensorDeviceClass.OCCUPANCY, "Doorbell"),
}


async def async_setup_platform(hass: HomeAssistant, config, async_add_entities, discovery_info=None) -> None:
    async_add_entities(
        DetectionSensor(hass, camera, kind)
        for camera in hass.data[DOMAIN]["cameras"]
        for kind in KINDS
        if kind != "ring"
    )


class DetectionSensor(BinarySensorEntity):
    _attr_should_poll = False
    _attr_is_on = False

    def __init__(self, hass: HomeAssistant, camera: dict, kind: str) -> None:
        self._camera = camera
        self._types, device_class, label = KINDS[kind]
        self._attr_device_class = device_class
        self._attr_name = f"{camera['name']} {label} detected"
        self._attr_unique_id = f"eufynized_{camera['serial']}_{kind}"
        self.entity_id = f"binary_sensor.{object_id(hass, camera)}_{kind}_detected"
        self._off = None

    async def async_added_to_hass(self) -> None:
        self.async_on_remove(async_dispatcher_connect(self.hass, SIGNAL_EVENT, self._on_event))

    @callback
    def _on_event(self, event: dict) -> None:
        if event.get("channel") != self._camera["channel"] or event.get("eventType") not in self._types:
            return
        if self._off:
            self._off()
        self._attr_is_on = True
        self.async_write_ha_state()
        self._off = async_call_later(self.hass, ON_SECONDS, self._turn_off)

    @callback
    def _turn_off(self, _now) -> None:
        self._off = None
        self._attr_is_on = False
        self.async_write_ha_state()
