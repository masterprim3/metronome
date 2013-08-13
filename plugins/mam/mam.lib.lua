-- * Metronome IM *
--
-- This file is part of the Metronome XMPP server and is released under the
-- ISC License, please see the LICENSE file in this source package for more
-- information about copyright and licensing.

-- MAM Module Library

local module_host = module.host;
local dt = require "util.datetime".datetime;
local jid_bare = require "util.jid".bare;
local jid_join = require "util.jid".join;
local jid_split = require "util.jid".split;
local st = require "util.stanza";
local uuid = require "util.uuid".generate;
local storagemanager = storagemanager;
local load_roster = rostermanager.load_roster;
local ipairs, now, pairs, select, t_remove, tostring = ipairs, os.time, pairs, select, table.remove, tostring;
      
local xmlns = "urn:xmpp:mam:0";
local delay_xmlns = "urn:xmpp:delay";
local e2e_xmlns = "http://www.xmpp.org/extensions/xep-0200.html#ns";
local forward_xmlns = "urn:xmpp:forward:0";
local rsm_xmlns = "http://jabber.org/protocol/rsm";

local store_time = module:get_option_number("mam_save_time", 300);
local stores_cap = module:get_option_number("mam_stores_cap", 5000);
local max_length = module:get_option_number("mam_message_max_length", 3000);

local session_stores = {};
local storage = {};
local to_save = now();

local _M = {};

local function initialize_storage()
	storage = storagemanager.open(module_host, "archiving");
	return storage;
end

local function save_stores()
	to_save = now();
	for bare, store in pairs(session_stores) do
		local user = jid_split(bare);
		storage:set(user, store);
	end	
end

local function log_entry(session_archive, to, from, id, body)
	local uid = uuid();
	local entry = {
		from = from,
		to = to,
		id = id,
		body = body,
		timestamp = now(),
		uid = uid
	};

	local logs = session_archive.logs;
	
	if #logs > stores_cap then t_remove(logs, 1); end
	logs[#logs + 1] = entry;

	if now() - to_save > store_time then save_stores(); end
	return uid;
end

local function append_stanzas(stanzas, entry, qid)
	local to_forward = st.message()
		:tag("result", { xmlns = xmlns, queryid = qid, id = entry.id })
			:tag("forwarded", { xmlns = forward_xmlns })
				:tag("delay", { xmlns = delay_xmlns, stamp = dt(entry.timestamp) }):up()
				:tag("message", { to = entry.to, from = entry.from, id = entry.id })
					:tag("body"):text(entry.body):up();
	
	stanzas[#stanzas + 1] = to_forward;
end

local function generate_query(stanzas, start, fin, set, first, last, count)
	local query = st.stanza("query", { xmlns = xmlns });
	if start then query:tag("start"):text(dt(start)):up(); end
	if fin then query:tag("end"):text(dt(fin)):up(); end
	if set and #stanzas ~= 0 then
		query:tag("set", { xmlns = rsm_xmlns })
			:tag("first", { index = 0 }):text(first):up()
			:tag("last"):text(last):up()
			:tag("count"):text(tostring(#stanzas - (count - 1))):up();
	end
	
	return (((start or fin) or (set and #stanzas ~= 0)) and query) or nil;
end

local function generate_stanzas(store, start, fin, with, max, after, before, qid)
	local logs = store.logs;
	local stanzas = {};
	local query;
	
	local count = 1;
	local first, last, _after, _start, _end;
	local _before = true;
	
	if before == true then
		local to_fetch = #logs - max;
		
		if to_fetch <= 0 then to_fetch = false; end
		for i, entry in ipairs(logs) do
			if to_fetch and i >= to_fetch then
				if count == 1 then 
					first = entry.uid;
					_start = entry.timestamp;
				elseif count == max then
					last = entry.uid;
					_end = entry.timestamp;
				end
				append_stanzas(stanzas, entry, qid);
				count = count + 1;
			elseif not to_fetch then
				append_stanzas(stanzas, entry, qid);
				count = count + 1;
			end
		end
		if not to_fetch and #stanzas ~= 0 then
			local first_e, last_e = logs[1], logs[#logs];
			first, last = first_e.uid, last_e.uid;
			_start, _end = first_e.timestamp, last_e.timestamp;
		end

		query = generate_query(stanzas, (start or _start), (fin or _end), (max and true), first, last, count);
		return stanzas, query;
	end
	
	for _, entry in ipairs(logs) do
		local timestamp = entry.timestamp;
		local add = true;
		if after and not _after then
			if entry.uid == after then _after = true; else add = false; end
		elseif before then
			if entry.uid == before then _before = false; end
			if not _before then break; end
		end

		if add then
			if max and count ~= 1 and count > max then
				break; 
			elseif max and count == max then 
				last = entry.uid;
				_end = timestamp;
			end
			
			if with and not (jid_bare(entry.from) == with or jid_bare(entry.to) == with) then
				add = false;
			elseif (start and not fin) and not (timestamp >= start) then
				add = false;
			elseif (fin and not start) and not (timestamp <= fin) then
				add = false;
			elseif (start and fin) and not (timestamp >= start and timestamp <= fin) then
				add = false;
			end
		end
		
		if add then
			append_stanzas(stanzas, entry, qid);
			if max then
				if count == 1 then 
					first = entry.uid;
					_start = timestamp;
				end
				count = count + 1; 
			end
		end
	end
	
	query = generate_query(stanzas, (start or _start), (fin or _end), (max and true), first, last, count);
	return stanzas, query;
end

local function add_to_store(store, user, recipient)
	local prefs = store.prefs
	if prefs[recipient] and recipient ~= "default" then
		return true;
	else
		if prefs.default == "always" then 
			return true;
		elseif prefs.default == "roster" then
			local roster = load_roster(user, module_host);
			if roster[recipient] then return true; end
		end
		
		return false;
	end
end

local function get_prefs(store)
	local _prefs = store.prefs;

	local stanza = st.stanza("prefs", { xmlns = xmlns, default = _prefs.default or "never" });
	local always = st.stanza("always");
	local never = st.stanza("never");
	for jid, choice in pairs(_prefs) do
		if jid and jid ~= "default" then
			(choice and always or never):tag("jid"):text(jid):up();
		end
	end

	stanza:add_child(always):add_child(never);
	return stanza;
end

local function set_prefs(stanza, store)
	local _prefs = store.prefs;
	local prefs = stanza:child_with_name("prefs");
	
	local default = prefs.attr.default;
	if default and default ~= "always" and default ~= "never" and default ~= "roster" then
		return st.error_reply(stanza, "modify", "bad-request", "Default can be either: always, never or roster");
	end
	
	if default then _prefs.default= default; end

	local always = prefs:get_child("always");
	if always then
		for jid in always:childtags("jid") do _prefs[jid:get_text()] = true; end
	end

	local never = prefs:get_child("never");
	if never then
		for jid in never:childtags("jid") do _prefs[jid:get_text()] = false; end
	end
	
	local reply = st.reply(stanza);
	reply:add_child(get_prefs(store));

	return reply;
end

local function process_message(event, outbound)
	local message, origin = event.stanza, event.origin;
	if message.attr.type ~= "chat" and message.attr.type ~= "normal" then return; end
	local body = message:child_with_name("body");
	if not body then 
		return; 
	else
		body = body:get_text();
		if body:len() > max_length then return; end
		-- Drop OTR/E2E messages
		if message:get_child("c", e2e_xmlns) or body:find("^%?OTR.*") then return; end
	end
	
	local from, to = (message.attr.from or origin.full_jid), message.attr.to;
	local bare_from, bare_to = jid_bare(from), jid_bare(to);
	local bare_session, user;
	
	if outbound then
		bare_session = bare_sessions[bare_from];
		user = jid_split(from);
	else
		bare_session = bare_sessions[bare_to];
		user = jid_split(to);
	end
	
	local archive = bare_session and bare_session.archiving;
	
	if not archive and not outbound then -- assume it's an offline message
		local offline_overcap = module:fire_event("message/offline/overcap", { node = user });
		if not offline_overcap then archive = storage:get(user); end
	end

	if archive and add_to_store(archive, user, (outbound and bare_to) or bare_from) then
		local id = log_entry(archive, to, from, message.attr.id, body);
		if not bare_session then storage:set(user, archive); end
		if not outbound then message:tag("archived", { jid = bare_to, id = id }):up(); end
	else
		return;
	end	
end

local function pop_entry(logs, i, jid)
	if jid then
		if logs[i].jid == jid then t_remove(logs, i); end
	else
		t_remove(logs, i);
	end
end

local function purge_messages(archive, id, jid, start, fin)
	if not id and not jid and not start and not fin then
		archive.logs = {};
		return;
	end
	
	local logs = archive.logs;
	if id then
		for i, entry in ipairs(logs) do
			if entry.uid == id then t_remove(logs, i); break; end
		end
	elseif jid or start or fin then
		for i, entry in ipairs(logs) do
			local timestamp = entry.timestamp;
			if (start and not fin) and timestamp >= start then
				pop_entry(logs, i, jid);
			elseif (not start and fin) and timestamp <= fin then
				pop_entry(logs, i, jid);
			elseif (start and fin) and (timestamp >= start and timestamp <= fin) then
				pop_entry(logs, i, jid);
			end
		end
	end
end

_M.initialize_storage = initialize_storage;
_M.save_stores = save_stores;
_M.get_prefs = get_prefs;
_M.set_prefs = set_prefs;
_M.generate_stanzas = generate_stanzas;
_M.process_message = process_message;
_M.purge_messages = purge_messages;
_M.session_stores = session_stores;

return _M;