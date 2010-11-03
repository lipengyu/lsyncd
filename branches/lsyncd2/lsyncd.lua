--============================================================================
-- lsyncd.lua   Live (Mirror) Syncing Demon
--
-- License: GPLv2 (see COPYING) or any later version
--
-- Authors: Axel Kittenberger <axkibe@gmail.com>
--
-- This is the "runner" part of lsyncd. It containts all its high-level logic.
-- It works closely together with the lsyncd core in lsyncd.c. This means it
-- cannot be runned directly from the standard lua interpreter.
--============================================================================

----
-- A security measurement.
-- Core will exit if version ids mismatch.
--
if lsyncd_version then
	-- checks if the runner is being loaded twice 
	io.stderr:write(
		"You cannot use the lsyncd runner as configuration file!\n")
	os.exit(-1) -- ERRNO
end
lsyncd_version = "2.0beta1"

----
-- Shortcuts (which user is supposed to be able to use them as well)
--
log  = lsyncd.log
exec = lsyncd.exec
terminate = lsyncd.terminate

--============================================================================
-- Coding checks, ensure termination on some easy to do coding errors.
--============================================================================

-----
-- The array objects are tables that error if accessed with a non-number.
--
local Array = (function()
	-- Metatable
	local mt = {}

	-- on accessing a nil index.
	mt.__index = function(t, k) 
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for Array", 2)
		end
		return rawget(t, k)
	end

	-- on assigning a new index.
	mt.__newindex = function(t, k, v)
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for Array", 2)
		end
		rawset(t, k, v)
	end

	-- creates a new object
	local function new()
		local o = {}
		setmetatable(o, mt)
		return o
	end

	-- objects public interface
	return {new = new}
end)()


-----
-- The count array objects are tables that error if accessed with a non-number.
-- Additionally they maintain their length as "size" attribute.
-- Lua's # operator does not work on tables which key values are not 
-- strictly linear.
--
local CountArray = (function()
	-- Metatable
	local mt = {}

	-----
	-- key to native table
	local k_nt = {}
	
	-----
	-- on accessing a nil index.
	mt.__index = function(t, k) 
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for CountArray", 2)
		end
		return t[k_nt][k]
	end

	-----
	-- on assigning a new index.
	mt.__newindex = function(t, k, v)
		if type(k) ~= "number" then
			error("Key '"..k.."' invalid for CountArray", 2)
		end
		-- value before
		local vb = t[k_nt][k]
		if v and not vb then
			t._size = t._size + 1
		elseif not v and vb then
			t._size = t._size - 1
		end
		t[k_nt][k] = v
	end

	-- TODO
	local function iwalk(self)
		return ipairs(self[k_nt])
	end

	------
	-- returns the count
	local function size(self)
		return self._size
	end

	----
	-- creates a new count array
	local function new()
		-- k_nt is native table, private for this object.
		local o = {_size = 0, iwalk = iwalk, size = size, [k_nt] = {} }
		setmetatable(o, mt)
		return o
	end

	-- objects public interface
	return {new = new}
end)()


-----
-- Metatable to limit keys to those only presented in their prototype
--
local meta_check_prototype = {
	__index = function(t, k) 
		if not t.prototype[k] then
			error("tables prototype doesn't have key '"..k.."'.", 2)
		end
		return rawget(t, k)
	end,
	__newindex = function(t, k, v)
		if not t.prototype[k] then
			error("tables prototype doesn't have key '"..k.."'.", 2)
		end
		rawset(t, k, v)
	end
}

-----
-- Sets the prototype of a table limiting its keys to a defined list.
--
local function set_prototype(t, prototype) 
	t.prototype = prototype
	for k, _ in pairs(t) do
		if not t.prototype[k] and k ~= "prototype" then
			error("Cannot set prototype, conflicting key: '"..k.."'.", 2)
		end
	end
	setmetatable(t, meta_check_prototype)
end

----
-- Locks globals,
-- no more globals can be created
--
local function globals_lock()
	local t = _G
	local mt = getmetatable(t) or {}
	mt.__index = function(t, k) 
		if (k~="_" and string.sub(k, 1, 2) ~= "__") then
			error("Access of non-existing global.", 2)
		else
			rawget(t, k)
		end
	end
	mt.__newindex = function(t, k, v) 
		if (k~="_" and string.sub(k, 1, 2) ~= "__") then
			error("Lsyncd does not allow GLOBALS to be created on the fly." ..
			      "Declare '" ..k.."' local or declare global on load.", 2)
		else
			rawset(t, k, v)
		end
	end
	setmetatable(t, mt)
end

-----
-- Holds information about a delayed event for one origin/target.
--
local Delay = (function()
	-----
	-- Creates a new delay.
	-- 
	-- @param TODO
	local function new(ename, pathname, alarm)
		local o = {
			ename = ename,
			alarm = alarm,
			pathname = pathname,
		}
		return o
	end

	return {new = new}
end)()

-----
-- Holds information about one observed directory inclusively subdirs.
--
local Origin = (function()
	----
	-- TODO
	--
	local function new(source, targetident, config) 
		local o = {
			config = config,
			delays = CountArray.new(),
			delayname = {},
			source = source,
			targetident = targetident,
			processes = CountArray.new(),
		}
		return o
	end

	-- public interface
	return {new = new}
end)()

-----
-- Puts an action on the delay stack.
--
function Origin:delay(origin, ename, time, pathname, pathname2)
	log("Debug", "delay ", ename, " ", pathname)
	local o = origin
	local delays = o.delays
	local delayname = o.delayname

	if ename == "Move" and not o.config.move then
		-- if there is no move action defined, split a move as delete/create
		log("Debug", "splitting Move into Delete & Create")
		delay(o, "Delete", time, pathname,  nil)
		delay(o, "Create", time, pathname2, nil)
		return
	end

	-- creates the new action
	local alarm 
	-- TODO scope
	if time and o.config.delay then
		alarm = lsyncd.addto_clock(time, o.config.delay)
	else
		alarm = lsyncd.now()
	end
	local newd = Delay.new(ename, pathname, alarm)

	local oldd = delayname[pathname] 
	if oldd then
		-- if there is already a delay on this pathname.
		-- decide what should happen with multiple delays.
		if newd.ename == "MoveFrom" or newd.ename == "MoveTo" or
		   oldd.ename == "MoveFrom" or oldd.ename == "MoveTo" then
		   -- do not collapse moves
			log("Normal", "Not collapsing events with moves on ", pathname)
			-- TODO stackinfo
			return
		else
			local col = o.config.collapse_table[oldd.ename][newd.ename]
			if col == -1 then
				-- events cancel each other
				log("Normal", "Nullfication: ", newd.ename, " after ",
					oldd.ename, " on ", pathname)
				oldd.ename = "None"
				return
			elseif col == 0 then
				-- events tack
				log("Normal", "Stacking ", newd.ename, " after ",
					oldd.ename, " on ", pathname)
				-- TODO Stack pointer
			else
				log("Normal", "Collapsing ", newd.ename, " upon ",
					oldd.ename, " to ", col, " on ", pathname)
				oldd.ename = col
				return
			end
		end
		table.insert(delays, newd)
	else
		delayname[pathname] = newd
		table.insert(delays, newd)
	end
end

-----
-- Origins - a singleton
-- 
-- It maintains all configured directories to be synced.
--
local Origins = (function()
	-- the list of all origins
	local list = Array.new()
	
	-----
	-- inheritly copies all non integer keys from
	-- @cd copy destination
	-- to
	-- @cs copy source
	-- all integer keys are treated as new copy sources
	--
	local function inherit(cd, cs)
		-- first recurses into all integer keyed tables
		for i, v in ipairs(cs) do
			if type(v) == "table" then
				inherit(cd, v)
			end
		end
		-- does nothing further if source == destination (first step)
		if (cd == cs) then
			return
		end
		-- then copies from the source all non integer keyed values 
		for k, v in pairs(cs) do
			if type(k) ~= "number" and not cd[k] then
				cd[k] = v
			end
		end
	end
	
	-----
	-- Adds a new directory to observe.
	--
	local function add(config)
		inherit(config, config)

		-- raises an error if 'name' isnt in opts
		local function require_opt(name)
			if not config[name] then
				local info = debug.getinfo(3, "Sl")
				log("Error", info.short_src, ":", info.currentline,
					": ", name, " missing from sync.")
				terminate(-1) -- ERRNO
			end
		end
		require_opt("source")
		require_opt("target")

		-- absolute path of source
		local real_src = lsyncd.real_dir(config.source)
		if not real_src then
			log(Error, "Cannot access source directory: ", config.source)
			terminate(-1) -- ERRNO
		end
		config.source = real_src

		if not config.action and not config.attrib and
		   not config.create and not config.modify and
		   not config.delete and not config.move
		then
			local info = debug.getinfo(2, "Sl")
			log("Error", info.short_src, ":", info.currentline,
				": no actions specified, use e.g. 'config=default.rsync'.")
			terminate(-1) -- ERRNO
		end

		-- loads a default value for an option if not existent
		local function optional(name)
			if config[name] then
				return
			end
			config[name] = settings[name] or default[name]
		end

		optional("action")
		optional("max_processes")
		optional("collapse_table")
		local o = Origin.new(config.source, config.target, config)
		table.insert(list, o)
	end

	-- allows to walk through all origins
	local function iwalk()
		return ipairs(list)
	end

	-- returns the number of origins
	local size = function()
		return #list
	end

	-- public interface
	return {add = add, iwalk = iwalk, size = size}
end)()

-----
-- Interface to inotify, watches recursively subdirs and 
-- sends events.
--
-- All inotify specific implementation should be enclosed here.
-- So lsyncd can work with other notifications mechanisms just
-- by changing this.
--
local Inotifies = (function()
	-----
	-- A list indexed by inotifies watch descriptor.
	-- Contains a list of all origins observing this directory
	-- (directly or by recurse)
	local wdlist = CountArray.new()

	-----
	-- Adds watches for a directory including all subdirectories.
	--
	-- @param root      root directory to observer
	-- @param origin    link to the observer to be notified.
	--                  Note: Inotifies should handle this opaquely
	-- @param recurse   true if recursing into subdirs
	--                  or the relative path to root for recurse
	--
	local function add(root, origin, recurse)
		-- register watch and receive watch descriptor
		local dir
		if type(recurse) == "string" then
			dir = root..recurse
		else 
			dir = root
			if recurse then
				recurse = ""
			end
		end
		local wd = lsyncd.add_watch(dir);
		if wd < 0 then
			-- failed adding the watch
			log("Error", "Failure adding watch ", dir, " -> ignored ")
			return
		end

		local ilist = wdlist[wd]
		if not ilist then
			ilist = Array.new()
			wdlist[wd] = ilist
		end
		local inotify = { root = root, path = recurse, origin = origin } 
		table.insert(ilist, inotify)

		-- registers and adds watches for all subdirectories 
		if recurse then
			local subdirs = lsyncd.sub_dirs(dir)
			for _, dirname in ipairs(subdirs) do
				add(root, origin, dir..dirname.."/")
			end
		end
	end

	-----
	-- Called when an event has occured.
	--
	-- @param ename     "Attrib", "Mofify", "Create", "Delete", "Move")
	-- @param wd        watch descriptor (matches lsyncd.add_watch())
	-- @param isdir     true if filename is a directory
	-- @param time      time of event
	-- @param filename  string filename without path
	-- @param filename2 
	--
	function event(ename, wd, isdir, time, filename, filename2)
		local ftype;
		if isdir then
			ftype = "directory"
		else
			ftype = "file"
		end
		if filename2 then
			log("Debug", "got event ", ename, " of ", ftype, " ", filename, 
				" to ", filename2) 
		else 
			log("Debug", "got event ", ename, " of ", ftype, " ", filename) 
		end

		local ilist = wdlist[wd]
		-- looks up the watch descriptor id
		if not ilist then
			-- this is normal in case of deleted subdirs
			log("Normal", "event belongs to unknown/deleted watch descriptor.")
			return
		end
	
		-- works through all observers interested in this directory
		for _, inotify in ipairs(ilist) do
			local pathname = inotify.path .. filename
			local pathname2 
			if filename2 then
				pathname2 = inotify.path..filename2
			end
			Origin.delay(inotify.origin, ename, time, pathname, pathname2)
			-- add subdirs for new directories
			if inotify.recurse and isdir then
				if ename == "Create" then
					add(inotify.root, inotify.origin, 
						inotify.path.."/"..filename)
					-- TODO remove /
				end
			end
		end
	end

	-----
	-- Writes a status report about inotifies to a filedescriptor
	--
	local function status_report(fd)
		local w = lsyncd.writefd
		w(fd, "Watching ", wdlist:size(), " directories\n")
		for wd, v in wdlist:iwalk() do
			w(fd, "  ", wd, ": ")
			for _, v in ipairs(v) do
				w(fd, "(", v.root, "/", (v.path) or ")")
			end
			w(fd, "\n")
		end
	end

	-----
	-- Returns the number of directories watched in total.
	local function size()
		return wdlist:size()
	end

	-- public interface
	return { add = add, size = size, status_report = status_report }
end)()

--============================================================================
-- lsyncd runner plugs. These functions will be called from core. 
--============================================================================

-----
-- Called from core whenever a lua failed.
--
function lsyncd_call_error(message)
	log("Error", "IN LUA: ", message)
	-- prints backtrace
	local level = 2
	while true do
		local info = debug.getinfo(level, "Sl")
		if not info then
			terminate(-1) -- ERRNO
		end
		log("Error", "Backtrace ", level - 1, " :", 
			info.short_src, ":", info.currentline)
		level = level + 1
	end
end

-----
-- Called from code whenever a child process finished and 
-- zombie process was collected by core.
--
function lsyncd_collect_process(pid, exitcode) 
	local delay = nil
	local origin = nil
	for _, o in Origins.iwalk() do
		delay = o.processes[pid]
		if delay then
			origin = o
			break
		end
	end
	if not delay then
		return
	end
	log("Debug", "collected ", pid, ": ", 
		delay.ename, " of ", origin.source, delay.pathname,
		" = ", exitcode)
	origin.processes[pid] = nil
end

------
-- Hidden key for lsyncd.lua internal variables not ment for
-- the user to see
--
local hk = {}

------
--- TODO
local inlet = {
	[hk] = {
		origin  = true,
		delay   = true,
	},

	config = function(self)
		return self[hk].origin.config
	end,

	nextevent = function(self)
		local h = self[hk]
		return { 
			spath  = h.origin.source .. h.delay.pathname,
			tpath  = h.origin.targetident .. h.delay.pathname,
			ename  = h.delay.ename
		} 
	end,
}


-----
-- TODO
--
--
local function invoke_action(origin, delay)
	local o       = origin
	local config  = o.config
	if delay.ename == "None" then
		-- a removed action
		return
	end
	
	inlet[hk].origin = origin
	inlet[hk].delay  = delay
	local pid = config.action(inlet)
	if pid and pid > 0 then
		o.processes[pid] = delay
	end
end
	

----
-- Called from core to get a status report written into a file descriptor
--
function lsyncd_status_report(fd)
	local w = lsyncd.writefd
	w(fd, "Lsyncd status report at ", os.date(), "\n\n")
	Inotifies.status_report(fd)
end

----
-- Called from core everytime at the latest of an 
-- expired alarm (or more often)
--
-- @param now   the time now
--
function lsyncd_alarm(now)
	-- goes through all targets and spawns more actions
	-- if possible
	for _, o in Origins.iwalk() do
		if o.processes:size() < o.config.max_processes then
			local delays = o.delays
			local d = delays[1]
			if d and lsyncd.before_eq(d.alarm, now) then
				invoke_action(o, d)
				table.remove(delays, 1)
				o.delayname[d.pathname] = nil -- TODO grab from stack
			end
		end
	end
end


-----
-- Called by core before anything is "-help" or "--help" is in
-- the arguments.
--
function lsyncd_help()
	io.stdout:write(
[[TODO this is a multiline
help
]])
	os.exit(-1) -- ERRNO
end


----
-- Called from core on init or restart after user configuration.
-- 
function lsyncd_initialize(args)
	-- creates settings if user didnt
	settings = settings or {}

	-- From this point on, no globals may be created anymore
	globals_lock()

	-- parses all arguments
	for i = 1, #args do
		local a = args[i]
		if a:sub(1, 1) ~= "-" then
			log("Error", "Unknown option ", a,
				". Options must start with '-' or '--'.")
			os.exit(-1) -- ERRNO
		end
		if a:sub(1, 2) == "--" then
			a = a:sub(3)
		else
			a = a:sub(2)
		end
		--TODO
	end

	-- all valid settings, first value is 1 if it needs a parameter 
	local configure_settings = {
		statusfile = {1, nil},
	}

	-- check all entries in the settings table
	for c, p in pairs(settings) do
		local cs = configure_settings[c]
		if not cs then
			log("Error", "unknown setting '", c, "'")	
			terminate(-1) -- ERRNO
		end
		if cs[1] == 1 and not p then
			log("Error", "setting '", c, "' needs a parameter")	
		end
		-- calls the check function if its not nil
		if cs[2] then
			cs[2](p)
		end
		lsyncd.configure(c, p)
	end

	-- makes sure the user gave lsyncd anything to do 
	if Origins.size() == 0 then
		log("Error", "Nothing to watch!")
		log("Error", "Use sync(SOURCE, TARGET, BEHAVIOR) in your config file.");
		terminate(-1) -- ERRNO
	end

	-- set to true if at least one origin has a startup function
	local have_startup = false
	-- runs through the origins table filled by user calling directory()
	for _, o in Origins.iwalk() do
		if o.config.startup then
			have_startup = true
		end
		-- adds the dir watch inclusively all subdirs
		Inotifies.add(o.source, "", true)
	end

	-- from now on use logging as configured instead of stdout/err.
	lsyncd.configure("running");
	
	if have_startup then
		log("Normal", "--- startup ---")
		local pids = { }
		for _, o in Origins.iwalk() do
			local pid
			if o.config.startup then
				local pid = o.config.startup(o.source, o.targetident)
				table.insert(pids, pid)
			end
		end
		lsyncd.wait_pids(pids, "startup_collector")
		log("Normal", "- Entering normal operation with ",
			Inotifies.size(), " monitored directories -")
	else
		log("Normal", "- Warmstart into normal operation with ",
			Inotifies.size(), " monitored directories -")
	end
end

----
-- Called by core to query soonest alarm.
--
-- @return two variables.
--         boolean false   ... no alarm, core can in untimed sleep
--                 true    ... alarm time specified.
--         times           ... the alarm time (only read if number is 1)
function lsyncd_get_alarm()
	local have_alarm = false
	local alarm = 0
	for _, o in Origins.iwalk() do
		if o.delays[1] and 
		   o.processes:size() < o.config.max_processes then
			if have_alarm then
				alarm = lsyncd.earlier(alarm, o.delays[1].alarm)
			else
				alarm = o.delays[1].alarm
				have_alarm = true
			end
		end
	end
	return have_alarm, alarm
end

lsyncd_inotify_event = Inotifies.event

-----
-- Collector for every child process that finished in startup phase
--
-- Parameters are pid and exitcode of child process
--
-- Can return either a new pid if one other child process 
-- has been spawned as replacement (e.g. retry) or 0 if
-- finished/ok.
--
function startup_collector(pid, exitcode)
	if exitcode ~= 0 then
		log("Error", "Startup process", pid, " failed")
		terminate(-1) -- ERRNO
	end
	return 0
end


--============================================================================
-- lsyncd user interface
--============================================================================

sync = Origins.add

----
-- Called by core when an overflow happened.
--
function default_overflow()
	log("Error", "--- OVERFLOW on inotify event queue ---")
	terminate(-1) -- TODO reset instead.
end
overflow = default_overflow

-----
-- Spawns a child process using bash.
--
function shell(command, ...)
	return exec("/bin/sh", "-c", command, "/bin/sh", ...)
end

--============================================================================
-- lsyncd default settings
--============================================================================

-----
-- lsyncd classic - sync with rsync
--
local default_rsync = {
	----
	-- Called for every sync/target pair on startup
	startup = function(source, target) 
		log("Normal", "startup recursive rsync: ", source, " -> ", target)
		return exec("/usr/bin/rsync", "-ltrs", 
			source, target)
	end,

	default = function(source, target, path)
		return exec("/usr/bin/rsync", "--delete", "-ltds",
			source.."/"..path, target.."/"..path)
	end
}

-----
-- The default table for the user to access 
--   TODO make readonly
-- 
default = {
	-----
	-- Default action
	-- TODO desc
	--
	action = function(inlet)
		local event = inlet:nextevent()
		local func = inlet:config()[string.lower(event.ename)]
		if func then
			return func(event)
		else 
			return -1
		end
	end,

	-----
	-- TODO
	--
	max_processes = 1,

	------
	-- TODO
	--
	collapse_table = {
		Attrib = { Attrib = "Attrib", Modify = "Modify", Create = "Create", Delete = "Delete" },
		Modify = { Attrib = "Modify", Modify = "Modify", Create = "Create", Delete = "Delete" },
		Create = { Attrib = "Create", Modify = "Create", Create = "Create", Delete = -1       },
		Delete = { Attrib = "Delete", Modify = "Delete", Create = "Modify", Delete = "Delete" },
	},

	rsync = default_rsync
}


