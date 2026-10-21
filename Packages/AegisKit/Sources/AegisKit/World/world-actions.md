<!-- Source: God's Eye View (MIT), src/voice/actionSchemas.js, gevRealtime.js and layerManifest.js; pinned commit 93ea088f4556a5a65b3292a2d15142d5a6c562bc in Apps/AegisApp/Resources/World. -->
Signatures: ? = optional, | = enum, [] = array, {} = object. All actions take an arguments object, including {} for no arguments. Enum aliases below are strings.
City = austin|sf|nyc|tokyo|london|paris|dubai|dc.
Layer = gnss-integrity|flights|military|local-adsb|ais-live-vessels|satellites|rocket-launches|earthquakes|local-firms|fire-perimeters|weather-cyclones|weather-radar|weather-satellite|weather-lightning|wind|air-quality|traffic|transit|bikeshare|radio|street-level|recent-imagery|directions|military-installations|local-datacenters|local-dams|telegeography-submarine-cables|cctv|alpr-cameras.
ContextLayer = local-adsb|ais-live-vessels|local-firms|military-installations|local-datacenters|local-dams.
QueryLayer = flights|military|local-adsb|ais-live-vessels|satellites|rocket-launches|earthquakes|local-firms|fire-perimeters|weather-cyclones|air-quality|transit|bikeshare|military-installations|local-datacenters|local-dams.
Point = {target?: string, latitude?: number, longitude?: number, screenX?: number, screenY?: number}.
Annotation = {type: pin|highlight|area|arrow|route|label, target?: string, points?: Point[], mode?: walking|driving|cycling, latitude?: number, longitude?: number, toTarget?: string, toLatitude?: number, toLongitude?: number, label?: string, color?: primary|amber|cyan|green|red, footprint?: boolean, intent?: the_thing|around_the_thing, entityKind?: building|compound|district|street|point_feature, screenX?: number, screenY?: number, toScreenX?: number, toScreenY?: number}.
Coordinates are degrees (latitude -90..90, longitude -180..180); screen coordinates are 0..1. referent is an entity reference from context, not a place name.
Analyst fields (numbers carry units in their names; times are epoch milliseconds or ISO strings): flights/military: altitudeM,speedMps,verticalRateMps,heading,callsign,icao24,originCountry,operator,aircraftClass,military,onGround,squawk,emergency,emergencyKind,emergencySource,emergencyBroadcast,lastContactAtMs; flights also routeOrigin,routeDestination. local-adsb: altitudeM,speedKts,heading,callsign,icao24,onGround. ais-live-vessels: speedKts,courseDeg,name,mmsi,shipType,destination. satellites: altitudeM,speedMps,name,noradId,satelliteClass,group. rocket-launches: name,provider,status,launchSite,missionName,launchTimeMs,hoursUntil. earthquakes: magnitude,depthKm,place,timeMs (last 24h). local-firms: frp(MW),confidence(0..1),satellite,sensor,acqTime (last 24h). fire-perimeters: acres,containedPct,personnel,costToDate,name,state,county,cause,behavior,complexity,discoveredTime. weather-cyclones: name,classification,basin,windKt,pressureHpa. air-quality: value,band,scale,provider,name,zone,risk,observedMs. transit: mode,routeId,speedMps,courseDeg,status,occupancy. bikeshare: bikesAvailable,docksAvailable,capacity,name,city,renting. military-installations: name,class,kind. local-datacenters: name,operator,capacity. local-dams: name,operator,river,output. Queries cover loaded data; satellite distances are ground distances, not overhead passes.

- `fly_to_location(locationId?: City, query?: string, latitude?: number, longitude?: number, viewMode?: close|overview, rangeM?: number, waitForArrival?: boolean, referent?: integer)` — Fly to a public place or coordinates; rangeM is 100..20000000 metres.
- `select_nearest_aircraft(layerId: flights|military, locationId?: City, locationQuery?: string, latitude?: number, longitude?: number)` — Select the nearest aircraft to a place.
- `adjust_camera_zoom(direction: in|out, amount: little|medium|lot)` — Zoom the globe view in or out.
- `zoom_to_globe()` — Show the whole globe.
- `set_layer_visibility(layerId: Layer, enabled: boolean)` — Show or hide a public data layer.
- `show_data_layers_menu(layerId?: Layer)` — Open the data layers menu, optionally at one layer.
- `set_panel_open(panelId: data-panel|location-bar|control-panel|radio-panel|scene-panel|pp-toggles|global-context-panel|weather-panel|recent-imagery-panel, open: boolean)` — Open or close a globe panel.
- `set_context_mode(mode: off|contacts|flights|space-missions|missions)` — Set the global context display mode.
- `control_cockpit(action: enter|exit|previous|next|prev|status, targetLayer?: flights|military|ais-live-vessels|military-installations, aircraftClass?: string)` — Enter, leave or cycle the cockpit view.
- `set_visual_style(style: normal|retro|surveillance|thermal|anime|noir|snow)` — Change the globe's visual style.
- `get_entity_context(scope?: auto|selected|in_view|pointer, referent?: integer, layerId?: ContextLayer, limit?: number)` — Inspect selected, visible or pointed-at entities, up to 12.
- `get_current_view_state()` — Read the current globe view state.
- `set_hud(visible?: on|off|auto, layout?: string)` — Set HUD visibility or layout.
- `set_cyber_sonar(enabled?: boolean, rings?: integer, rangePct?: integer, intensityPct?: integer, opacityPct?: integer, sectorDeg?: integer)` — Adjust sonar visuals (rings 3..12, rangePct 60..120, intensityPct 0..100, opacityPct 35..100, sectorDeg 8..60).
- `set_detection(enabled?: boolean, mode?: sparse|balanced|dense, densityPct?: number, allocationStrategy?: elastic|weighted)` — Adjust detection markers and their density.
- `set_map_stack(stack: photoreal|bing-aerial|bing-labels|esri-imagery|osm)` — Switch the base map or 3D imagery.
- `set_post_processing(bloom?: {enabled?: boolean, intensityPct?: number}, sharpen?: {enabled?: boolean, intensityPct?: number})` — Adjust bloom and sharpening effects.
- `control_scene(action: list|play|stop|next|status, sceneId?: string)` — List or control a scripted globe scene.
- `control_radio(action: enable|disable|play|resume|pause|stop|next|previous|volume|select|status, volumePct?: number, category?: all|news|talk|weather|public-safety|aviation-marine|traffic-transit|music, locationId?: City, locationQuery?: string, latitude?: number, longitude?: number, country?: string, stationQuery?: string)` — Select or control public radio stations; volumePct is 0..100.
- `track_entity(query?: string, layerId?: string, referent?: -1|1|2|3|4|5)` — Follow a named entity or context reference; query or referent is required.
- `stop_tracking()` — Stop following an entity.
- `frame_overhead(target: flights|military|satellites|vessels, radiusKm?: number)` — Frame overhead entities of the chosen kind.
- `annotate_map(annotations: Annotation[], flyTo?: boolean, persist?: boolean)` — Add 1..24 pins, labels, areas, highlights, arrows or routes; route points number 2..12.
- `clear_annotations()` — Clear the map's annotations.
- `move_camera(motion: orbit|pan|tilt|rotate|stop, direction?: left|right|up|down, speed?: slow|normal|fast, mode?: once|continuous)` — Move or stop the globe viewpoint.
- `fly_route(label?: string, speed?: slow|normal|fast)` — Fly along an annotated route.
- `analyst_query(layers?: QueryLayer[], scope?: {kind?: view|region|radius|anywhere|pointer, name?: string, km?: number, center?: {lat: number, lon: number}}, filters?: {field: string, op: gt|gte|lt|lte|eq|neq|contains, value: any}[], sortBy?: string, sortDir?: asc|desc, limit?: number, followUp?: boolean)` — Count, filter or rank loaded public entities in a scope.
- `next_iss_pass(latitude?: number, longitude?: number, minElevationDeg?: number)` — Find the next ISS pass; minimum elevation is 5..60 degrees.
- `next_satellite_pass(target: string, latitude?: number, longitude?: number, minElevationDeg?: number, visibleOnly?: boolean)` — Find the next pass of a named satellite; minimum elevation is 5..60 degrees.
- `control_cctv(action: enable|disable|select|next|prev|nearest|focus|coverage|viewshed|adjust|projection|autohop, cameraQuery?: string, enabled?: boolean)` — Public traffic and CCTV cameras: show or hide them, pick, step through or focus a camera, show coverage.
