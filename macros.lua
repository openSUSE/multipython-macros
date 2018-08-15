function _python_scan_spec()
    local last_python = rpm.expand("%python_for_executables")
    local insert_last_python = false

    pythons = {}
    -- make sure that last_python is the last item in the list
    for str in string.gmatch(rpm.expand("%pythons"), "%S+") do
        if str == last_python then
            insert_last_python = true
        else
            table.insert(pythons, str)
        end
    end
    -- ...but check that it is actually in the buildset
    if insert_last_python then table.insert(pythons, last_python) end

    modname = rpm.expand("%name")
    local spec_name_prefix = "python"
    -- modname from name
    local name = modname
    for _,py in ipairs(pythons) do
        if name:find(py .. "%-") == 1 then
            spec_name_prefix = py
            modname = name:sub(py:len() + 2)
            break
        end
    end
    -- try to match "python-"
    if name == modname and name:find("python%-") == 1 then
        spec_name_prefix = "python"
        modname = name:sub(8)
    end
    -- if not found, modname == %name, spec_name_prefix == "python"

    system_python = rpm.expand("%system_python")
    -- is the package built for python2 as "python-foo" ?
    old_python2 = rpm.expand("%python2_prefix") == "python"
    is_called_python = spec_name_prefix == "python"

    -- detect `flavor`, used for evaluating %ifmacros
    if is_called_python then
        -- either system_python (if found in %pythons)
        -- or the last entry of %pythons
        for _,py in ipairs(pythons) do
            flavor = py
            if flavor == system_python then break end
        end
    else
        -- specname is something other than "python-", and it is a valid
        -- python flavor (otherwise spec_name_prefix defaults to "python"
        -- so `is_called_python` is true), so we use it literally
        flavor = spec_name_prefix
    end

    -- find the spec file
    specpath = rpm.expand("%_specfile")

    -- search possible locations - shouldn't be necessary anymore
--    local locations = { rpm.expand("%_sourcedir"), rpm.expand("%_specdir"), posix.getcwd(), posix.getcwd() .. "/" .. name }
--    for _,loc in ipairs(locations) do
--        local filename = loc .. "/" .. name .. ".spec"
--        if posix.stat(filename, "mode") ~= nil then
--            io.stderr:write("could not find spec as " .. filename .. "\n")
--            specpath = filename
--            break
--        end
--    end
end

function python_subpackages()
    rpm.expand("%_python_macro_init")
    _python_subpackages_emitted = true

    local current_flavor  = flavor
    local original_flavor = rpm.expand("%python_flavor")

    -- line processing functions
    local function print_altered(line)
        -- set %name macro to proper flavor-name
        line = line:gsub("%%{?name}?", current_flavor .. "-" .. modname)
        -- print expanded
        print(rpm.expand(replace_macros(line, current_flavor)) .. "\n")
    end

    local function ignore_line(line) end

    local function files_line(line)
        -- unexpand %license at start of line
        if line:startswith("%license") then
            line = "%" .. line
        end
        return print_altered(line)
    end

    local PROPERTY_COPY_UNMODIFIED = lookup_table { "Summary:", "Version:", "BuildArch:" }
    local PROPERTY_COPY_MODIFIED = lookup_table {
        "Requires:", "Provides:",
        "Recommends:", "Suggests:",
        "Conflicts:", "Obsoletes:",
        "Supplements:", "Enhances:",
        "%requires_eq", "%requires_ge",
        "Requires(pre):", "Requires(preun):", "Requires(post):", "Requires(postun):",
        "Requires(pretrans):", "Requires(posttrans):",
    }

    local function process_package_line(line)
        -- This function processes lines like "Requires: something something".
        -- "Requires: python-foo" -> "Requires: python3-foo"
        -- "Requires: %{name} = %{version}" -> "Requires: python3-modname = %{version}"
        -- "Supplements: packageand(python-a:python-b)" -> "Supplements: packageand(python3-a:python3-b)"
        -- you get the idea.
        -- TODO implement %$flavor_only support here?

        -- first split Property: value
        local property, value = line:match("^([A-Z%%]%S+)%s*(.*)$")

        -- "python-foo" -> "python3-foo"
        local function rename_package(package, flavor)
            if package == "python" or package == flavor then
                -- specialcase plain "python"
                package = current_flavor
            else
                package = package:gsub("^" .. flavor .. "(%W)", current_flavor .. "%1")
                package = package:gsub("^python(%W)", current_flavor .. "%1")
            end
            return package
        end

        -- split and rewrite "packageand(a:b:c)", using rename_package() for each of a, b, c
        local function fix_packageand(packageand, flavor)
            local inner = packageand:match("^packageand%((.*)%)$")
            if not inner then return packageand end
            local eat = inner
            local result = "packageand("
            while eat do
                local idx = eat:find(":")
                local n = ""
                if idx then
                    n = eat:sub(1, idx)
                    eat = eat:sub(idx+1)
                else
                    n = eat
                    eat = nil
                end
                n = n:gsub("^%s*", "")
                result = result .. rename_package(n, flavor)
            end
            return result .. ")"
        end

        if PROPERTY_COPY_UNMODIFIED[property] then
            print_altered(line)
        elseif PROPERTY_COPY_MODIFIED[property] then
            -- specifically handle %name macro before expansion
            line = line:gsub("%%{?name}?", current_flavor .. "-" .. modname)
            -- convert value using the appropriate function
            if value:startswith("packageand") then
                value = fix_packageand(value, flavor)
            else
                value = rename_package(value, flavor)
            end
            -- rely on print_altered to perform expansion on the result
            print_altered(string.format("%s %s", property, value))
        end
    end

    local auto_posttrans = {}
    local auto_posttrans_current = {}
    local auto_posttrans_backslash = false

    local function expect_alternatives(line)
        if auto_posttrans_backslash then
            local apc = auto_posttrans_current
            apc[#apc] = apc[#apc] .. "\n" .. line
            auto_posttrans_backslash = line:endswith("\\")
        elseif line:startswith("%python_install_alternative")
            or line:startswith("%{python_install_alternative") -- "}"
            or line:startswith("%" .. flavor .. "_install_alternative")
            or line:startswith("%{" .. flavor .. "_install_alternative") -- "}"
            then
                table.insert(auto_posttrans_current, line)
                auto_posttrans_backslash = line:endswith("\\")
        else
            auto_posttrans_backslash = false
        end
        return print_altered(line)
    end
    -- end line processing functions

    local function print_obsoletes(modname)
        if current_flavor == "python2" then
            print(rpm.expand("Obsoletes: python-" .. modname .. " < %{version}-%{release}\n"))
            print(rpm.expand("Provides: python-" .. modname .. " = %{version}-%{release}\n"))
        end
    end

    local function files_headline(flavor, param)
        if not param then param = "" end
        local append = param:match("(%-f%s+%S+)")
        local nof = param:gsub("%-f%s+%S+%s*", "")
        local python_files = param:match("%%{?python_files}?")
        local subpkg = param:match("%%{python_files%s*(.-)}")
        if subpkg then python_files = true end

        if is_called_python and not python_files then
            -- kingly hack. but RPM's native %error does not work.
            local errmsg =
                'error: Package with "python-" prefix must not contain unmarked "%files" sections.\n' ..
                'error: Use "%files %python_files" or "%files %{python_files foo} instead.\n'
            io.stderr:write(errmsg)
            print(errmsg)
            error('Invalid spec file')
        end

        local mymodname = nof
        if python_files then mymodname = subpkg end
        return "%files -n " .. package_name(flavor, modname, mymodname, append) .. "\n"
    end

    local function section_headline(section, flavor, param)
        if section == "files" then
            return files_headline(flavor, param)
        else
            return "%" .. section .. " -n " .. package_name(flavor, modname, param) .. "\n"
        end
    end

    local python2_binsuffix = rpm.expand("%python2_bin_suffix")
    local function dump_alternatives_posttrans()
        if not old_python2 and current_flavor == "python2" then
            for label, value in pairs(auto_posttrans) do
                if value ~= false then
                    print(section_headline("posttrans", current_flavor, label))
                    for _,line in ipairs(value) do
                        -- RPM needs {} characters in Lua macros to match, so
                        -- this is an opening "{" for this one: ----------v
                        firstarg = line:match("install_alternative%s+([^%s}]+)")
                        if firstarg then
                            local _,_,path = python_alternative_names(firstarg, python2_binsuffix)
                            print(string.format('if [ -e "%s" ]; then\n', path))
                            print_altered(line)
                            print("fi\n")
                        end
                    end
                end
            end
        end
        auto_posttrans = {}
    end

    local function should_expect_alternatives(section, param)
        if old_python2 or current_flavor ~= "python2" then return false end
        if param == nil then param = "" end
        if section == "posttrans" then
            auto_posttrans[param] = false
            return false
        end
        if section == "post" and auto_posttrans[param] ~= false then
            auto_posttrans_current = {}
            auto_posttrans[param] = auto_posttrans_current
            return true
        end
        return false
    end

    local function match_braces(line)
        local count = 0
        for c in line:gmatch(".") do
            if c == "{" then count = count + 1
            elseif c == "}" and count > 0 then count = count - 1
            end
        end
        return count == 0
    end

    local KNOWN_SECTIONS = lookup_table {"package", "description", "files", "prep",
        "build", "install", "check", "clean", "pre", "post", "preun", "postun",
        "pretrans", "posttrans", "changelog"}
    local COPIED_SECTIONS = lookup_table {"description", "files",
        "pre", "post", "preun", "postun", "pretrans", "posttrans"}

    -- before we start, print Provides: python2-modname
    if is_called_python and old_python2 then
        print(rpm.expand("Provides: python2-" .. modname .. " = %{version}-%{release}\n"))
    end

    for _,python in ipairs(pythons) do
        local is_current_flavor = python == flavor
        -- "python-foo" case:
        if is_called_python then
            if old_python2 then
                -- if we're in old-style package, "python" == "python2"
                is_current_flavor = python == "python2"
            else
                -- else nothing is current flavor, always generate
                is_current_flavor = false
            end
        end

        current_flavor = python

        -- rescan spec for each flavor
        if not is_current_flavor then
            local spec, err = io.open(specpath, "r")
            if err then print ("could not find spec file at path: " .. specpath) return end

            rpm.define("python_flavor " .. python)

            local section_function = process_package_line
            print(section_headline("package", current_flavor, nil))
            print_obsoletes(modname)

            while true do
                -- collect lines until braces match. it's what rpm does, kind of.
                local eof = false
                local line = spec:read()
                if line == nil then break end
                while not match_braces(line) do
                    local nl = spec:read()
                    if nl == nil then eof = true break end
                    line = line .. "\n" .. nl
                end
                if eof then break end
                --io.stderr:write(current_flavor .. " >".. tostring(line) .."<\n")

                -- match section delimiter
                local section_noparam = line:match("^%%(%S+)(%s*)$")
                local section_withparam, param = line:match("^%%(%S+)%s+(.+)$")
                local newsection = section_noparam or section_withparam

                if KNOWN_SECTIONS[newsection] then
                    -- enter new section
                    if param and param:startswith("-n") then
                        -- ignore named section
                        section_function = ignore_line
                    elseif newsection == "package" then
                        print(section_headline("package", current_flavor, param))
                        print_obsoletes(modname .. "-" .. param)
                        section_function = process_package_line
                    elseif newsection == "files" and current_flavor == flavor then
                        section_function = ignore_line
                    elseif COPIED_SECTIONS[newsection] then
                        print(section_headline(newsection, current_flavor, param))
                        if should_expect_alternatives(newsection, param) then
                            section_function = expect_alternatives
                        elseif newsection == "files" then
                            section_function = files_line
                        else
                            section_function = print_altered
                        end
                    else
                        section_function = ignore_line
                    end
                elseif line:startswith("%python_subpackages") then
                    -- ignore
                elseif line:startswith("%if") then
                    -- RPM handles %if on top level, whole sections can be conditional.
                    -- We must copy the %if declarations always, even if they are part
                    -- of non-copied sections. Otherwise we miss this:
                    -- %files A
                    -- /bin/something
                    -- %if %condition
                    -- %files B
                    -- /bin/otherthing
                    -- %endif
                    print_altered(line)
                    -- We are, however, copying expanded versions. This way, specifically,
                    -- macros like %ifpython3 are evaluated differently in the top-level spec
                    -- itself and in the copied sections.
                    --io.stderr:write(rpm.expand(line) .. "\n")
                elseif line:startswith("%else") or line:startswith("%endif") then
                    print(line .. "\n")
                    --io.stderr:write(line .. "\n")
                else
                    section_function(line)
                end
            end

            dump_alternatives_posttrans()

            spec:close()
        end
    end

    -- restore %python_flavor for further processing
    rpm.define("python_flavor " .. original_flavor)
end

function python_exec(+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-=)
    local args = rpm.expand("%**")
    print(rpm.expand("%{python_expand %__$python " .. args .. "}"))
end

function python_expand(+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-=)
    -- force spec scan
    rpm.expand("%_python_macro_init")
    local args = rpm.expand("%**")
    for _, python in ipairs(pythons) do
        print(rpm.expand("%{_python_use_flavor " .. python .. "}\n"))
        local cmd = replace_macros(args, python)
        cmd = cmd:gsub("$python", python)
        print(rpm.expand(cmd .. "\n"))
    end
end

function python_build(+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-=)
    rpm.expand("%_python_macro_init")
    for _, python in ipairs(pythons) do
        print(rpm.expand("%" .. python .. "_build %**"))
    end
end

function python_install(+abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-=)
    rpm.expand("%_python_macro_init")
    for _, python in ipairs(pythons) do
        print(rpm.expand("%" .. python .. "_install %**"))
    end
end

function python_files()
    rpm.expand("%_python_macro_init")
    local nparams = rpm.expand("%#")
    local param = ""
    if tonumber(nparams) > 0 then param = rpm.expand("%1") end

    print("-n " .. package_name(flavor, modname, param))

    if not _python_subpackages_emitted then
        print("\n/%python_subpackages_macro_not_present\n")
        io.stderr:write("%python_subpackages macro not present\n"
            .. "(To get rid of this error, either add a %python_subpackages macro to preamble "
            .. "or remove %python_files.\n")
        error("%python_subpackages macro not present\n")
    end
end

function python_clone(a)
    rpm.expand("%_python_macro_init")
    local param = rpm.expand("%1")
    local link, name, path
    for _, python in ipairs(pythons) do
        local binsuffix = rpm.expand("%" .. python .. "_bin_suffix")
        link,name,path = python_alternative_names(param, binsuffix, true)
        print(rpm.expand(string.format("cp %s %s\n", param, path)))
        print(rpm.expand(string.format("sed -ri '1s@#!.*python.*@#!/usr/bin/%s@' %s\n", python, path)))
    end

    -- %python_clone -a
    if rpm.expand("%{?-a}") == "-a" then
        local buildroot = rpm.expand("%{buildroot}")
        if link:startswith(buildroot) then link = link:sub(buildroot:len() + 1) end
        print(rpm.expand(string.format("%%{prepare_alternative -t %s %s}\n", link, name)))
    end
end

function python_module()
    rpm.expand("%_python_macro_init")
    local params = rpm.expand("%**")
    for _, python in ipairs(pythons) do
        if python == "python2" then
            print(rpm.expand("%python2_prefix") .. "-" .. params)
        else
            print(python .. "-" .. params)
        end
        print(" ")
    end
end
