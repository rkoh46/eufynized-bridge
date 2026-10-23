"""Eufynized: your eufy cameras in Home Assistant, straight from the HomeBase.

The Eufynized bridge (a container next to Home Assistant) talks to the HomeBase over its local P2P protocol and
serves the Security Camera page. This integration puts that page in the sidebar behind Home Assistant's own
login (like an add-on's ingress: a per-session path the panel asks for over the authenticated websocket), and
turns the HomeBase's events into `eufynized_event` on the event bus, with optional phone pushes.

It also adds entities: each camera (snapshots, and a stream for HA's own camera cards), motion/person/
crying/sound/pet/vehicle sensors that turn on for a few seconds per event, the latest event's picture, and the
HomeBase's guard mode as an alarm panel.

configuration.yaml:

    eufynized:
      url: http://127.0.0.1:18099        # the bridge (default)
      notify_service: mobile_app_iphone   # optional: pushes, when "Push to phone" is on in the Alerts tab
      entity_names:                       # optional: entity name per camera serial (default: the camera's name)
        T8162T0000000001: backyard
      alarm_entity_name: eufy_home_base   # optional (default: eufynized_home_base)
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import time
from pathlib import Path

import aiohttp
import voluptuous as vol
from aiohttp import web

from homeassistant.components import frontend, websocket_api
from homeassistant.components.http import HomeAssistantView, StaticPathConfig
from homeassistant.const import EVENT_HOMEASSISTANT_STOP
from homeassistant.core import HomeAssistant, callback
from homeassistant.helpers import config_validation as cv, discovery
from homeassistant.helpers.dispatcher import async_dispatcher_send
from homeassistant.helpers.aiohttp_client import async_get_clientsession
from homeassistant.helpers.typing import ConfigType

_LOGGER = logging.getLogger(__name__)

DOMAIN = "eufynized"
EVENT = "eufynized_event"
PANEL_URL = "security-camera"
STATIC_URL = "/eufynized_static"
PROXY_PREFIX = "/api/eufynized/s"
SESSION_TTL = 12 * 3600
SIGNAL_EVENT = "eufynized_camera_event"
SIGNAL_GUARD = "eufynized_guard_mode"
PLATFORMS = ["camera", "binary_sensor", "image", "alarm_control_panel", "switch", "sensor", "select"]

CONFIG_SCHEMA = vol.Schema(
    {
        DOMAIN: vol.Schema(
            {
                vol.Optional("url", default="http://127.0.0.1:18099"): cv.url,
                vol.Optional("notify_service", default=""): cv.string,
                vol.Optional("sidebar_title", default="Security Camera"): cv.string,
                vol.Optional("sidebar_icon", default="mdi:cctv"): cv.icon,
                vol.Optional("entity_names", default={}): {cv.string: cv.slug},
                vol.Optional("alarm_entity_name", default="eufynized_home_base"): cv.slug,
            }
        )
    },
    extra=vol.ALLOW_EXTRA,
)


class Sessions:
    """Random path tokens handed to signed-in users; each use extends it."""

    def __init__(self) -> None:
        self._tokens: dict[str, float] = {}

    def new(self) -> str:
        now = time.monotonic()
        self._tokens = {t: exp for t, exp in self._tokens.items() if exp > now}
        token = secrets.token_urlsafe(32)
        self._tokens[token] = now + SESSION_TTL
        return token

    def check(self, token: str) -> bool:
        now = time.monotonic()
        expires = self._tokens.get(token)
        if expires is None or expires < now:
            return False
        self._tokens[token] = now + SESSION_TTL
        return True


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    conf = config[DOMAIN]
    base = conf["url"].rstrip("/")
    sessions = Sessions()
    hass.data[DOMAIN] = {"url": base, "sessions": sessions, "config": conf, "cameras": [], "guard_mode": None}

    await hass.http.async_register_static_paths(
        [StaticPathConfig(STATIC_URL, str(Path(__file__).parent / "frontend"), cache_headers=False)]
    )
    hass.http.register_view(ProxyView(hass, base, sessions))
    websocket_api.async_register_command(hass, ws_session)

    frontend.async_register_built_in_panel(
        hass,
        component_name="custom",
        sidebar_title=conf["sidebar_title"],
        sidebar_icon=conf["sidebar_icon"],
        frontend_url_path=PANEL_URL,
        require_admin=False,
        config={
            "_panel_custom": {
                "name": "eufynized-panel",
                "module_url": f"{STATIC_URL}/panel.js?v=1.1.0",
                "embed_iframe": False,
                "trust_external": False,
            }
        },
    )

    # The dashboard card (`custom:eufynized-card`), available on every dashboard.
    frontend.add_extra_js_url(hass, f"{STATIC_URL}/card.js?v=1.1.1")

    task = hass.async_create_background_task(_follow_events(hass, base, conf["notify_service"]), "eufynized events")

    hass.bus.async_listen("mobile_app_notification_action", lambda ev: hass.async_create_task(_on_notification_action(hass, base, ev)))
    hass.async_create_background_task(_load_entities(hass, base, config), "eufynized entities")

    @callback
    def _stop(_event) -> None:
        task.cancel()

    hass.bus.async_listen_once(EVENT_HOMEASSISTANT_STOP, _stop)
    return True


@websocket_api.websocket_command({vol.Required("type"): "eufynized/session"})
@callback
def ws_session(hass: HomeAssistant, connection: websocket_api.ActiveConnection, msg: dict) -> None:
    """A path token for the panel's frame (the user is already signed in on this websocket)."""
    sessions: Sessions = hass.data[DOMAIN]["sessions"]
    connection.send_result(msg["id"], {"path": f"{PROXY_PREFIX}/{sessions.new()}/"})


async def _load_entities(hass: HomeAssistant, base: str, config: ConfigType) -> None:
    """Reads the camera list from the bridge (retrying while it starts), then sets up the entity platforms."""
    session = async_get_clientsession(hass)
    delay = 5
    while True:
        try:
            async with session.get(f"{base}/api/cameras", timeout=aiohttp.ClientTimeout(total=15)) as resp:
                cameras = await resp.json()
            async with session.get(f"{base}/api/guard", timeout=aiohttp.ClientTimeout(total=15)) as resp:
                hass.data[DOMAIN]["guard_mode"] = (await resp.json()).get("mode")
            break
        except Exception as err:  # noqa: BLE001 - the bridge may still be starting
            _LOGGER.debug("Eufynized bridge not ready: %s", err)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60)
    hass.data[DOMAIN]["cameras"] = cameras
    for platform in PLATFORMS:
        hass.async_create_task(discovery.async_load_platform(hass, platform, DOMAIN, {}, config))


def object_id(hass: HomeAssistant, camera: dict) -> str:
    """The entity name for a camera: from `entity_names` (to keep a former integration's entity IDs), else its name."""
    names = hass.data[DOMAIN]["config"]["entity_names"]
    from homeassistant.util import slugify

    return names.get(camera["serial"]) or slugify(camera["name"])


async def _follow_events(hass: HomeAssistant, base: str, notify_service: str) -> None:
    """Every HomeBase event → `eufynized_event`; ones the Alerts tab lets through → a phone push."""
    session = async_get_clientsession(hass)
    service = notify_service.removeprefix("notify.")
    delay = 5
    while True:
        try:
            if service:
                async with session.put(f"{base}/api/alerts/settings", json={"notifyService": service}) as resp:
                    await resp.read()
            async with session.get(
                f"{base}/api/alerts/stream", params={"all": "1"}, timeout=aiohttp.ClientTimeout(total=None, sock_read=90)
            ) as resp:
                delay = 5
                async for raw in resp.content:
                    line = raw.decode(errors="ignore").strip()
                    if not line.startswith("data:"):
                        continue
                    try:
                        event = json.loads(line[5:])
                    except ValueError:
                        continue
                    if event.get("type") == "guard":
                        hass.data[DOMAIN]["guard_mode"] = event.get("mode")
                        async_dispatcher_send(hass, SIGNAL_GUARD, event.get("mode"))
                        continue
                    async_dispatcher_send(hass, SIGNAL_EVENT, event)
                    hass.bus.async_fire(
                        EVENT,
                        {
                            "title": event.get("title"),
                            "kind": event.get("kind"),
                            "camera": event.get("camera"),
                            "channel": event.get("channel"),
                            "time": event.get("time"),
                            "event_type": event.get("eventType"),
                            "alert": event.get("alert", False),
                            "detail": event.get("detail"),
                        },
                    )
                    if service and event.get("push"):
                        hass.async_create_task(_push(hass, service, event))
        except asyncio.CancelledError:
            raise
        except Exception as err:  # noqa: BLE001 - keep following whatever goes wrong
            _LOGGER.debug("Eufynized event stream: %s", err)
        await asyncio.sleep(delay)
        delay = min(delay * 2, 60)


async def _push(hass: HomeAssistant, service: str, event: dict) -> None:
    """A phone push with the picture and buttons: View live, Snooze 30 min, False alarm (the Home Assistant
    app shows them on a long press). Button presses come back as `mobile_app_notification_action`."""
    title = f"{event.get('title')} · {event.get('camera')}"
    channel = event.get("channel")
    message = event.get("detail") or f"{event.get('camera')}: {str(event.get('title', '')).lower()}"
    data = {
        "tag": f"eufynized-{channel}",
        "group": "eufynized",
        "url": f"/{PANEL_URL}",
        "clickAction": f"/{PANEL_URL}",
        "actions": [{"action": "URI", "title": "View live", "uri": f"/{PANEL_URL}"}],
    }
    if event.get("kind") not in ("health", "digest"):
        data["actions"] += [
            {"action": f"EUFYNIZED_SNOOZE_{channel}", "title": "Snooze 30 min"},
            {"action": f"EUFYNIZED_FALSE_{event.get('id')}", "title": "False alarm"},
        ]
    try:
        await hass.services.async_call("notify", service, {"title": title, "message": message, "data": data}, blocking=False)
    except Exception as err:  # noqa: BLE001
        _LOGGER.warning("Eufynized push through notify.%s failed: %s", service, err)


async def _on_notification_action(hass: HomeAssistant, base: str, event) -> None:
    """A button on one of our pushes: snooze the camera, or record a false alarm."""
    action = str(event.data.get("action", ""))
    session = async_get_clientsession(hass)
    try:
        if action.startswith("EUFYNIZED_SNOOZE_"):
            channel = int(action.rsplit("_", 1)[1])
            async with session.post(f"{base}/api/cameras/{channel}/snooze", json={"minutes": 30}) as resp:
                await resp.read()
        elif action.startswith("EUFYNIZED_FALSE_"):
            async with session.post(f"{base}/api/alerts/false-alarm", json={"id": action[len("EUFYNIZED_FALSE_"):]}) as resp:
                await resp.read()
    except Exception as err:  # noqa: BLE001
        _LOGGER.warning("Eufynized notification action %s failed: %s", action, err)


FORWARD_REQUEST = {"content-type", "range", "accept", "last-event-id", "if-none-match"}
FORWARD_RESPONSE = {"content-type", "content-range", "accept-ranges", "cache-control", "etag"}
STREAMED = {"text/event-stream", "video/mp2t", "multipart/x-mixed-replace"}


class ProxyView(HomeAssistantView):
    """The Security Camera page and its API, for holders of a session path (see `ws_session`)."""

    url = PROXY_PREFIX + "/{token}/{path:.*}"
    name = "api:eufynized:proxy"
    requires_auth = False

    def __init__(self, hass: HomeAssistant, base: str, sessions: Sessions) -> None:
        self._hass = hass
        self._base = base
        self._sessions = sessions

    async def _handle(self, request: web.Request, token: str, path: str) -> web.StreamResponse:
        if not self._sessions.check(token):
            return web.Response(status=401, text="Session expired: reopen Security Camera.")
        url = f"{self._base}/{path}"
        if request.headers.get("Upgrade", "").lower() == "websocket":
            return await self._websocket(request, url)

        session = async_get_clientsession(self._hass)
        headers = {k: v for k, v in request.headers.items() if k.lower() in FORWARD_REQUEST}
        body = await request.read()
        try:
            resp = await session.request(
                request.method,
                url,
                params=request.query,
                data=body or None,
                headers=headers,
                timeout=aiohttp.ClientTimeout(total=None, sock_connect=10),
                allow_redirects=False,
                auto_decompress=False,
            )
        except aiohttp.ClientError as err:
            return web.Response(status=502, text=f"The Eufynized bridge isn't answering: {err}")
        try:
            out = {k: v for k, v in resp.headers.items() if k.lower() in FORWARD_RESPONSE}
            if resp.content_type in STREAMED or "Content-Length" not in resp.headers:
                stream = web.StreamResponse(status=resp.status, headers=out)
                await stream.prepare(request)
                async for chunk in resp.content.iter_any():
                    await stream.write(chunk)
                return stream
            return web.Response(status=resp.status, body=await resp.read(), headers=out)
        except (ConnectionResetError, aiohttp.ClientError):
            return web.Response(status=499)
        finally:
            resp.release()

    async def _websocket(self, request: web.Request, url: str) -> web.WebSocketResponse:
        server = web.WebSocketResponse(autoping=True)
        await server.prepare(request)
        session = async_get_clientsession(self._hass)
        try:
            async with session.ws_connect(url, params=request.query, autoping=True, max_msg_size=0) as client:

                async def browser_to_bridge() -> None:
                    async for msg in server:
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            await client.send_str(msg.data)
                        elif msg.type == aiohttp.WSMsgType.BINARY:
                            await client.send_bytes(msg.data)
                        else:
                            break

                async def bridge_to_browser() -> None:
                    async for msg in client:
                        if msg.type == aiohttp.WSMsgType.TEXT:
                            await server.send_str(msg.data)
                        elif msg.type == aiohttp.WSMsgType.BINARY:
                            await server.send_bytes(msg.data)
                        else:
                            break

                tasks = [asyncio.create_task(browser_to_bridge()), asyncio.create_task(bridge_to_browser())]
                _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
        except (aiohttp.ClientError, ConnectionResetError) as err:
            _LOGGER.debug("Eufynized video socket: %s", err)
        finally:
            await server.close()
        return server

    get = post = put = _handle
