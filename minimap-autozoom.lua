--[[
* Addons - Copyright (c) 2026 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
*
* minimap-autozoom was inspired by lin's minimap-helper,
* https://github.com/mousseng/xitools, which sets the zoom from a value you
* type. This one records the zoom as you use it instead.
--]]

addon.name      = 'minimap-autozoom';
addon.author    = 'AddonsXI';
addon.version   = '1.1.0';
addon.link      = 'https://github.com/AddonsXI';
addon.desc      = 'Automatically remembers the minimap zoom level you set in each zone';

require('common');

local ZONE_PACKET     = 0x0A;
local WM_MOUSEWHEEL   = 522;
local IDLE_SAVE_DELAY = 3000;
local DEFAULT_ZOOM    = '0.5';
local MIN_ZOOM        = 0.1;
local POLL_DELAY      = 500;
local MAX_ZONE        = 9999;
local HELPER_ADDON    = 'minimap-helper';
local SHARED_FILE     = 'zones.lua';

local zones      = { };
local dirty      = { };
local currentKey = nil;
local idleSaveAt = nil;
local pollAt     = 0;

local function InstallRoot()
    return AshitaCore:GetInstallPath():gsub('[\\/]+$', '');
end

local function AddonConfigDir(name)
    return ('%s\\config\\addons\\%s'):format(InstallRoot(), name);
end

local function SharedPath()
    return ('%s\\%s'):format(AddonConfigDir(addon.name), SHARED_FILE);
end

local function GetMinimapConfigPath()
    return ('%s\\config\\minimap\\minimap.ini'):format(InstallRoot());
end

local function ReadCurrentZoom()
    local file = io.open(GetMinimapConfigPath(), 'r');
    if (file == nil) then
        return nil;
    end

    local section = nil;
    local zoom = nil;

    for line in file:lines() do
        local header = line:match('^%s*%[([^%]]+)%]');

        if (header ~= nil) then
            section = header:lower();
        elseif (section == 'main') then
            local value = line:match('^%s*zoom%s*=%s*([%d%.]+)');

            if (value ~= nil) then
                zoom = tonumber(value);
                break;
            end
        end
    end

    file:close();
    return zoom;
end

local function ReadZonesFrom(path)
    local file = io.open(path, 'r');
    if (file == nil) then
        return nil, 0;
    end

    local found = { };
    local count = 0;

    for line in file:lines() do
        local key, value = line:match('^%s*settings%[(%d+)%]%s*=%s*"([^"]*)"');
        local id = tonumber(key);

        if (id ~= nil and id <= MAX_ZONE and (tonumber(value) or 0) >= MIN_ZOOM) then
            found[id] = value;
            count = count + 1;
        end
    end

    file:close();
    return found, count;
end

local function WriteZones(path, source)
    local keys = { };
    for key in pairs(source) do
        keys[#keys + 1] = key;
    end
    table.sort(keys);

    local file = io.open(path, 'w');
    if (file == nil) then
        return false;
    end

    file:write('require(\'common\');\n\nlocal settings = T{ };\n');

    for _, key in ipairs(keys) do
        file:write(('settings[%d] = "%s";\n'):format(key, source[key]));
    end

    file:write('\nreturn settings;\n');
    file:close();
    return true;
end

local function CollectFrom(addonName)
    local base = AddonConfigDir(addonName);
    local found = { };

    local entries = ashita.fs.get_directory(base, '.*');
    if (entries == nil) then
        return found;
    end

    for _, entry in ipairs(entries) do
        if (entry:match('^.+_%d+$') ~= nil) then
            local saved, count = ReadZonesFrom(('%s\\%s\\settings.lua'):format(base, entry));

            if (saved ~= nil and count > 0) then
                found[#found + 1] = { zones = saved, count = count };
            end
        end
    end

    return found;
end

local function Migrate()
    local shared = SharedPath();

    if (ashita.fs.exists(shared)) then
        return;
    end

    local sources = { };

    for _, source in ipairs(CollectFrom(addon.name)) do
        sources[#sources + 1] = source;
    end

    for _, source in ipairs(CollectFrom(HELPER_ADDON)) do
        sources[#sources + 1] = source;
    end

    table.sort(sources, function(a, b) return a.count < b.count; end);

    local merged = { };
    local total = 0;

    for _, source in ipairs(sources) do
        for key, value in pairs(source.zones) do
            if (merged[key] == nil) then
                total = total + 1;
            end

            merged[key] = value;
        end
    end

    local dir = AddonConfigDir(addon.name);
    if (not ashita.fs.exists(dir)) then
        local partial = '';
        for segment in dir:gmatch('[^\\]+') do
            partial = (#partial == 0) and segment or (partial .. '\\' .. segment);
            ashita.fs.create_directory(partial);
        end
    end

    if (WriteZones(shared, merged) and total > 0) then
        print(('[%s] %d zones are now shared across all your characters.'):format(addon.name, total));
    end
end

local function RefreshFromDisk()
    local disk = ReadZonesFrom(SharedPath());

    if (disk == nil) then
        return;
    end

    for key in pairs(dirty) do
        disk[key] = zones[key];
    end

    zones = disk;
end

local function SaveZones()
    if (next(dirty) == nil) then
        return;
    end

    local disk = ReadZonesFrom(SharedPath()) or { };

    for key in pairs(dirty) do
        disk[key] = zones[key];
    end

    if (WriteZones(SharedPath(), disk)) then
        zones = disk;
        dirty = { };
    end
end

local function CurrentKey()
    local zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0);

    if (zone == nil or zone == 0) then
        return nil;
    end

    return zone;
end

local function StoreZoom(key)
    if (key == nil) then
        return;
    end

    local zoom = ReadCurrentZoom();
    if (zoom == nil or zoom < MIN_ZOOM) then
        return;
    end

    local value = ('%g'):format(zoom);
    if (zones[key] ~= value) then
        zones[key] = value;
        dirty[key] = true;
        SaveZones();
    end
end

local function RestoreZoom(key)
    if (key == nil) then
        return;
    end

    local zoom = zones[key];
    if (zoom == nil or (tonumber(zoom) or 0) < MIN_ZOOM) then
        zoom = DEFAULT_ZOOM;
    end

    AshitaCore:GetChatManager():QueueCommand(1, ('/minimap zoom %s'):format(zoom));
end

local function SwitchTo(key)
    if (key == nil or key == currentKey) then
        return;
    end

    if (currentKey ~= nil) then
        StoreZoom(currentKey);
    end

    idleSaveAt = nil;
    currentKey = key;

    RefreshFromDisk();
    RestoreZoom(key);
end

ashita.events.register('load', 'load_cb', function ()
    Migrate();
    RefreshFromDisk();
    SwitchTo(CurrentKey());
end);

ashita.events.register('packet_in', 'packet_in_cb', function (e)
    if (e.id == ZONE_PACKET) then
        pollAt = 0;
    end
end);

ashita.events.register('mouse', 'mouse_cb', function (e)
    if (e.message == WM_MOUSEWHEEL) then
        idleSaveAt = ashita.time.get_tick() + IDLE_SAVE_DELAY;
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    local now = ashita.time.get_tick();

    if (now >= pollAt) then
        pollAt = now + POLL_DELAY;
        SwitchTo(CurrentKey());
    end

    if (idleSaveAt ~= nil and now >= idleSaveAt) then
        idleSaveAt = nil;
        StoreZoom(currentKey);
    end
end);

ashita.events.register('unload', 'unload_cb', function ()
    StoreZoom(currentKey);
end);
