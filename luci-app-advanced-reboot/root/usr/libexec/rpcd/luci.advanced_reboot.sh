#!/bin/sh
# Copyright 2017-2020 Stan Grishin (stangri@melmac.net)
# shellcheck disable=SC2039,SC1091


# https://openwrt.org/docs/techref/rpcd
# https://forum.openwrt.org/t/script-mount-alternate-nand-firmware-linksys/33588/3

readonly devices_dir="/usr/share/advanced-reboot/devices/"

. /usr/share/libubox/jshn.sh

logger() { /usr/bin/logger -t advanced-reboot "$1"; }

is_alt_mountable() {
	local p1_mtd="$1" p2_mtd="$2"
	if [ "${p1_mtd:0:3}" = "mtd" ] && [ "${p2_mtd:0:3}" = "mtd" ] && \
		[ -x "/usr/sbin/ubiattach" ] && \
		[ -x "/usr/sbin/ubiblock" ] && \
		[ -x "/bin/mount" ]; then
		return 0
	else
		return 1
	fi
}

alt_partition_mount() {
	local ubi_dev op_ubi="$1"
	for i in alt_rom alt_overlay firmware; do [ ! -d "$i" ] && mkdir -p "/alt/${i}"; done
	ubi_dev = "$(ubiattach -m $op_ubi)"
	ubi_dev="$(echo "$ubi_dev" | sed -n "s/^UBI device number\s*\(\d*\),.*$/\1/p")"
	if [ -z "$ubi_dev" ]; then 
		ubidetach -m "$op_ubi"
		return 1
	fi
	ubiblock --create "/dev/ubi${ubi_dev}_0"
	mount -t squashfs -o ro "/dev/ubiblock${ubi_dev}_0" /alt/alt_rom
	mount -t ubifs "/dev/ubi${ubi_dev}_0" /alt/alt_overlay
	# mount -t overlay overlay -o noatime,lowerdir=/alt/rom,upperdir=/alt/overlay/upper,workdir=/alt/overlay/work /alt/firmware
}

alt_partition_unmount() {
	local i="0" op_ubi="$1"
	local mtdCount = "$(ubinfo | grep 'Present UBI devices' | grep -c ',')"
	[ -z "$mtdCount" ] && mtdCount = 10
	# [ -d /alt/firmware ] && umount /alt/firmware
	[ -d /alt/alt_overlay ] && umount /alt/alt_overlay
	[ -d /alt/alt_rom ] && umount /alt/alt_rom
	while [ "$i" -le "$mtdCount" ]; do
		if [ ! -e "/sys/devices/virtual/ubi/ubi${i}/mtd_num" ]; then
			break
		fi
		ubi_mtd = "$(cat /sys/devices/virtual/ubi/ubi${i}/mtd_num)"
		if [ -n "$ubi_mtd" ] && [ "$ubi_mtd" = "$op_ubi" ]; then
			ubiblock --remove /dev/ubi${i}_0
			ubidetach -m "$op_ubi"
			rm -rf /alt
		fi
		i=$((i + 1))
	done
}

get_main_partition_os_info(){
	local cp_info
	if [ -s "/etc/os-release" ]; then
		cp_info="$(. /etc/os-release && echo "$PRETTY_NAME")"
		if [ "${cp_info//SNAPSHOT}" != "$cp_info" ]; then
			cp_info="$(. /etc/os-release && echo "$OPENWRT_RELEASE")"
		fi
	fi
	echo "$cp_info"
}

get_alt_partition_os_info(){
	local op_info op_ubi="$1"
	logger "attempting to mount alternative partition (mtd${op_ubi})"
	alt_partition_unmount op_ubi
	alt_partition_mount op_ubi
	if [ -s "/alt/alt_rom/etc/os-release" ]; then
		op_info="$(. /alt/alt_rom/etc/os-release && echo "$PRETTY_NAME")"
		if [ "${op_info//SNAPSHOT}" != "$op_info" ]; then
			op_info="$(. /alt/alt_rom/etc/os-release && echo "$OPENWRT_RELEASE")"
		fi
	fi
	logger "attempting to unmount alternative partition (mtd${op_ubi})"
	alt_partition_unmount op_ubi
	echo "$op_info"
}

find_device_data(){
	local boardNames filename romBoardName="$1"
	for filename in "${devices_dir}"*.json; do
		[ "$filename" = "${devices_dir}*.json" ] && return
		boardNames="$(jsonfilter -i "$filename" -l1 -e "@['boardNames']")"
		if [ "${boardNames//$romBoardName}" != "$boardNames" ]; then
			echo "$filename"
			return
		fi
	done
}

local methods = {
	obtain_device_info = {
		call = function()

			local ret = {}
			local romBoardName = fs.readfile('/tmp/sysinfo/board_name')

# json_init
# json_add_string error 'NO_BOARD_NAME'
# json_dump

			if not romBoardName then
				ret.error = 'NO_BOARD_NAME'
				return ret
			end

			romBoardName = romBoardName:gsub('\n','')

			ret.rom_board_name = romBoardName

			romBoardName = romBoardName:gsub('%p','')

			local p, boardName, n, p1_label, p1_version, p2_label, p2_version, p1_os, p2_os
			local current_partition
			local op_ubi, cp_info, op_info, zyxelFlagPartition

			p = find_device_data(romBoardName)

			if p then
				if p.labelOffset then
					if p.partition1MTD then
						p1_label = util.trim(util.exec("dd if=/dev/" .. p.partition1MTD .. " bs=1 skip=" .. p.labelOffset .. " count=128" .. " 2>/dev/null"))
						n, p1_version = p1_label:match('(Linux)-([%d|.]+)')
					end

					if p1_label then
						if p1_label:find("LEDE") then p1_os = "LEDE" end
						if p1_label:find("OpenWrt") then p1_os = "OpenWrt" end
						if p.vendorName and p1_label:find(p.vendorName) then p1_os = p.vendorName end
					end

					if not p1_os then
						p1_os = (p.vendorName and p.vendorName or 'Unknown') .. "/" .. "Unknown"
					end
					if p1_os and p1_version then p1_os = p1_os .. " (Linux " .. p1_version .. ")" end

					if p.partition2MTD then
						p2_label = util.trim(util.exec("dd if=/dev/" .. p.partition2MTD .. " bs=1 skip=" .. p.labelOffset .. " count=128" .. " 2>/dev/null"))
						n, p2_version = p2_label:match('(Linux)-([%d|.]+)')
					end

					if p2_label then
						if p2_label:find("LEDE") then p2_os = "LEDE" end
						if p2_label:find("OpenWrt") then p2_os = "OpenWrt" end
						if p.vendorName and p2_label:find(p.vendorName) then p2_os = p.vendorName end
					end

					if not p2_os then
						p2_os = (p.vendorName and p.vendorName or 'Unknown') .. "/" .. "Unknown"
					end
					if p2_os and p2_version then p2_os = p2_os .. " (Linux " .. p2_version .. ")" end
				else
					p1_os = p.vendorName .. "/" .. "Unknown" .. " (" .. "Compressed" .. ")"
					p2_os = p.vendorName .. "/" .. "Unknown" .. " (" .. "Compressed" .. ")"
				end

				if p.bootEnv1 then
					if fs.access("/usr/sbin/fw_printenv") and fs.access("/usr/sbin/fw_setenv") then
						current_partition = tonumber(util.trim(util.exec("fw_printenv -n " .. p.bootEnv1)))
					end
				else
					if not zyxelFlagPartition then zyxelFlagPartition = util.trim(util.exec(". /lib/functions.sh; find_mtd_part 0:DUAL_FLAG")) end
					if zyxelFlagPartition then
						current_partition = tonumber(util.exec("dd if=" .. zyxelFlagPartition .. " bs=1 count=1 2>/dev/null | hexdump -n 1 -e '1/1 \"%d\"'"))
					else
						ret.error = 'NO_DUAL_FLAG'
						logger("Unable to find Dual Boot Flag Partition.")
						return ret
					end
				end

				ret.current_partition = current_partition

				if is_alt_mountable(p.partition1MTD, p.partition2MTD) then
					if current_partition == p.bootEnv1Partition1Value then
						op_ubi = tonumber(p.partition2MTD:sub(4)) + 1
					else
						op_ubi = tonumber(p.partition1MTD:sub(4)) + 1
					end
					local cp_info, op_info = get_partition_os_info(op_ubi)
					if current_partition == p.bootEnv1Partition1Value then
						p1_os = cp_info or p1_os
						p2_os = op_info or p2_os
					else
						p1_os = op_info or p1_os
						p2_os = cp_info or p2_os
					end
				end

				ret.device_name = (p.vendorName and p.vendorName or "") .. " " .. p.deviceName

				ret.partitions = {
					{
						os = p1_os,
						state = p.bootEnv1Partition1Value == current_partition and 'Current' or 'Alternative',
						number = p.bootEnv1Partition1Value
					},
					{
						os = p2_os,
						state = p.bootEnv1Partition2Value == current_partition and 'Current' or 'Alternative',
						number = p.bootEnv1Partition2Value
					}
				}
			end

			return ret
		end
	},
	toggle_boot_partition = {
		call = function()
			local ret = {}
			local zyxelFlagPartition, zyxelBootFlag, zyxelNewBootFlag, errorCode, curEnvSetting, newEnvSetting

			local romBoardName = fs.readfile('/tmp/sysinfo/board_name')

			if not romBoardName then
				ret.error = 'NO_BOARD_NAME'
				return ret
			end

			romBoardName = romBoardName:gsub('\n',''):gsub('%p','')
			p = find_device_data(romBoardName)
			local bev1, bev2 = p.bootEnv1, p.bootEnv2

			if bev1 or bev2 then -- Linksys devices
				if bev1 then
					curEnvSetting = tonumber(util.trim(util.exec("fw_printenv -n " .. bev1)))
					if not curEnvSetting then
						logger(string.format("Unable to obtain firmware environment variable: %s.", bev1))
						ret.error = 'NO_FIRM_ENV'
						ret.args = { bev1 }
						return ret
					else
						local bev1p1, bev1p2 = p.bootEnv1Partition1Value, p.bootEnv1Partition2Value
						newEnvSetting = curEnvSetting == bev1p1 and bev1p2 or bev1p1
						errorCode = sys.call("fw_setenv " .. bev1 .. " " .. newEnvSetting)
						if errorCode ~= 0 then
							logger(string.format("Unable to set firmware environment variable: %s to %s.", bev1, newEnvSetting))
							ret.error = 'ERR_SET_ENV'
							ret.args = { bev1, newEnvSetting }
							return ret
						end
					end
				end
				if bev2 then
					curEnvSetting = util.trim(util.exec("fw_printenv -n " .. bev2))
					if not curEnvSetting then
						logger(string.format("Unable to obtain firmware environment variable: %s.", bev2))
						ret.error = 'NO_FIRM_ENV'
						ret.args = { bev2 }
						return ret
					else
						local bev2p1, bev2p2 = p.bootEnv2Partition1Value, p.bootEnv2Partition1Value
						newEnvSetting = curEnvSetting == bev2p1 and bev2p2 or bev2p1
						errorCode = sys.call("fw_setenv " .. bev2 .. " '" .. newEnvSetting .. "'")
						if errorCode ~= 0 then
							logger(string.format("Unable to set firmware environment variable: %s to %s.", bev2, newEnvSetting))
							ret.error = 'ERR_SET_ENV'
							ret.args = { bev2, newEnvSetting }
							return ret
						end
					end
				end
			else -- NetGear device
				if not zyxelFlagPartition then zyxelFlagPartition = util.trim(util.exec(". /lib/functions.sh; find_mtd_part 0:DUAL_FLAG")) end
				if not zyxelFlagPartition then
					logger("Unable to find Dual Boot Flag Partition.")
					ret.error = 'NO_DUAL_FLAG'
				else
					zyxelBootFlag = tonumber(util.exec("dd if=" .. zyxelFlagPartition .. " bs=1 count=1 2>/dev/null | hexdump -n 1 -e '1/1 \"%d\"'"))
					zyxelNewBootFlag = zyxelBootFlag and zyxelBootFlag == 1 and "\\xff" or "\\x01"
					if zyxelNewBootFlag then
						errorCode = sys.call("printf \"" .. zyxelNewBootFlag .. "\" >" .. zyxelFlagPartition )
						if errorCode ~= 0 then
							logger(string.format("Unable to set Dual Boot Flag Partition entry for partition: %s.", zyxelFlagPartition))
							ret.error = 'ERR_SET_DUAL_FLAG'
							ret.args = { zyxelFlagPartition }
							return ret
						end
					end
				end
			end

			return ret
		end
	}
}

local function parseInput()
	local parse = json.new()
	local done, err

	while true do
		local chunk = io.read(4096)
		if not chunk then
			break
		elseif not done and not err then
			done, err = parse:parse(chunk)
		end
	end

	if not done then
		print(json.stringify({ error = err or "Incomplete input" }))
		os.exit(1)
	end

	return parse:get()
end

local function validateArgs(func, uargs)
	local method = methods[func]
	if not method then
		print(json.stringify({ error = "Method not found" }))
		os.exit(1)
	end

	if type(uargs) ~= "table" then
		print(json.stringify({ error = "Invalid arguments" }))
		os.exit(1)
	end

	uargs.ubus_rpc_session = nil

	local k, v
	local margs = method.args or {}
	for k, v in pairs(uargs) do
		if margs[k] == nil or
		   (v ~= nil and type(v) ~= type(margs[k]))
		then
			print(json.stringify({ error = "Invalid arguments" }))
			os.exit(1)
		end
	end

	return method
end

if arg[1] == "list" then
	local _, method, rv = nil, nil, {}
	for _, method in pairs(methods) do rv[_] = method.args or {} end
	print((json.stringify(rv):gsub(":%[%]", ":{}")))
elseif arg[1] == "call" then
	local args = parseInput()
	local method = validateArgs(arg[2], args)
	local result, code = method.call(args)
	print((json.stringify(result):gsub("^%[%]$", "{}")))
	os.exit(code or 0)
end
