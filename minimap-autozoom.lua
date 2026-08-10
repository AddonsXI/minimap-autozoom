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
addon.version   = '1.0.0';
addon.link      = 'https://github.com/AddonsXI';
addon.desc      = 'Automatically remembers the minimap zoom level you set in each zone';

require('common');
local settings = require('settings');

local ZONE_PACKET     = 0x0A;
local WM_MOUSEWHEEL   = 522;
local IDLE_SAVE_DELAY = 3000;
local DEFAULT_ZOOM    = '0.5';
local MIN_ZOOM        = 0.1;
local POLL_DELAY      = 500;
local HELPER_ADDON    = 'minimap-helper';

local config = settings.load(T{ });

local currentKey = nil;
local importDone = false;
local idleSaveAt = nil;
local pollAt     = 0;

settings.register('settings', 'settings_update', function (newConfig)
    if (newConfig ~= nil) then
        config = newConfig;
    end

    settings.save();
end);

local function GetMinimapConfigPath()
    local root = AshitaCore:GetInstallPath():gsub('[\\/]+$', '');
    return ('%s\\config\\minimap\\minimap.ini'):format(root);
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

local function HelperSettingsPath(name, serverId)
    local root = AshitaCore:GetInstallPath():gsub('[\\/]+$', '');
    local base = ('%s\\config\\addons\\%s'):format(root, HELPER_ADDON);

    local direct = ('%s\\%s_%d\\settings.lua'):format(base, name, serverId);
    if (ashita.fs.exists(direct)) then
        return direct;
    end

    local entries = ashita.fs.get_directory(base, '.*');
    if (entries == nil) then
        return nil;
    end

    for _, entry in ipairs(entries) do
        if (entry:match('^' .. name .. '_%d+$') ~= nil) then
            local path = ('%s\\%s\\settings.lua'):format(base, entry);
            if (ashita.fs.exists(path)) then
                return path;
            end
        end
    end

    return nil;
end

local function ImportFromHelper()
    if (importDone) then
        return;
    end

    if (next(config) ~= nil) then
        importDone = true;
        return;
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local name = party:GetMemberName(0);

    if (name == nil or name == '') then
        return;
    end

    importDone = true;

    local path = HelperSettingsPath(name, party:GetMemberServerId(0));
    if (path == nil) then
        return;
    end

    local file = io.open(path, 'r');
    if (file == nil) then
        return;
    end

    local count = 0;

    for line in file:lines() do
        local key, value = line:match('^%s*settings%[(%d+)%]%s*=%s*"([^"]*)"');

        if (key ~= nil and (tonumber(value) or 0) >= MIN_ZOOM) then
            config[tonumber(key)] = value;
            count = count + 1;
        end
    end

    file:close();

    if (count > 0) then
        settings.save();
        currentKey = nil;
        print(('[%s] picked up %d saved zones from %s.'):format(addon.name, count, HELPER_ADDON));
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
    if (config[key] ~= value) then
        config[key] = value;
        settings.save();
    end
end

local function RestoreZoom(key)
    if (key == nil) then
        return;
    end

    local zoom = config[key];
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
    RestoreZoom(key);
end

ashita.events.register('load', 'load_cb', function ()
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
        ImportFromHelper();
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
