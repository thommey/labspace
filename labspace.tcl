# LabSpace 1.0
# Copyright (C) 2011 Gunnar Beutner
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.

# TODO:
# [ ] texts
# [ ] highscores
# [-] different weapons
# [-] secret voting
# [ ] list remaining players after each round (for irssi users)
# [ ] document code
# [ ] performance counters
# [ ] advance game state if active scientist/investigator leaves the channel
# [ ] remove "Done." notice for votes?
# [ ] tweak sbnc's floodcontrol code

# configuration options
set ::ls_min_players 6
set ::ls_use_cmsg 1
set ::ls_debugmode 0

set ::ls_kill_messages {
	"%NICK% was brutally murdered."
	"%NICK% was vaporized by the scientist's death ray."
	"%NICK% slipped into a coma after drinking their poison-laced morning coffee."
	"%NICK% was crushed to death by a 5-ton boulder."
	"%NICK% couldn't escape from the scientist's killbot army."
}

set ::ls_event_handlers {
	ls_log_event_handler
	ls_stats_event_handler
}

if {![info exists ::ls_stats_events]} {
	set ::ls_stats_events [list]
}

package require sbnc 1.1

bind pub - !labspace ls_pub_cmd_labspace
bind pub - !nolabspace ls_pub_cmd_remove

bind pub - !add ls_pub_cmd_add
bind pub - !remove ls_pub_cmd_remove

bind pub - !wait ls_pub_cmd_wait

bind msg - kill ls_msg_cmd_kill
bind notc - kill* ls_notc_cmd_kill

bind msg - investigate ls_msg_cmd_investigate
bind notc - investigate* ls_notc_cmd_investigate

bind msg - vote ls_msg_cmd_vote
bind notc - vote* ls_notc_cmd_vote

bind msg n&- smite ls_msg_cmd_smite
bind notc n&- smite* ls_notc_cmd_smite

bind pubm - * ls_pubm_handler
bind part - * ls_leave_handler
bind sign - * ls_leave_handler
bind kick - * ls_kick_handler
bind nick - * ls_nick_handler

internaltimer 10 1 ls_timer_advance_state [getctx]

# work-around for a bug in sbnc's floodcontrol code
internaltimer 1 1 ls_bug_timer

proc ls_bug_timer {} {}

# clear game state when the bot gets disconnected from IRC
internalbind svrdisconnect ls_clear_state

internaltimer 10 1 ls_flush_stats

proc ls_clear_state {} {
	global ls_gamestate ls_gamestate_timeout ls_gamestate_delay

	array unset ls_gamestate
	array unset ls_gamestate_timeout
	array unset ls_gamestate_delay
}

# sends a debug message
proc ls_debug {chan message} {
	global ls_debugmode

	if {$ls_debugmode} {
		ls_putmsg $chan "DEBUG: $message"
	}
}

proc ls_log_event_handler {channel name arguments} {
	set file [open "labspace.log" "a"]
	puts $file "[unixtime] channel: $channel, name: $name, args: \"[join $arguments {" "}]\""
	close $file
}

proc ls_stats_event_handler {channel name arguments} {
	global ls_stats_events

	if {![info exists ls_stats_events]} {
		set ls_stats_events [list]
	}

	lappend ls_stats_events [list [clock seconds] $channel $name $arguments]
}

proc ls_flush_stats {} {
	global ls_stats_events

	if {![info exists ls_stats_events]} {
		return
	}

	setctx "stats"

	while {[llength $ls_stats_events] > 0} {
		set event [lindex $ls_stats_events 0]
		set timestamp [lindex $event 0]

		if {$timestamp > [expr {[clock seconds] - 600}]} {
			break
		}

		set ls_stats_events [lreplace $ls_stats_events 0 0]

		set channel [lindex $event 1]
		set name [lindex $event 2]
		set arguments [lindex $event 3]

#		putmsg "#labspace.stats" "channel: $channel, name: $name, args: \"[join $arguments {" "}]\""
	}
}

proc ls_post_event {channel name args} {
	global ls_event_handlers

	foreach event_handler $ls_event_handlers {
		$event_handler $channel $name $args
	}
}

# returns the name of a channel that can be used for CNOTICE/CPRIVMSG
# to send messages to the specified target, returns "" if no suitable
# channel was found or if use of CNOTICE/CPRIVMSG is disabled
proc ls_get_cmsg_chan {target} {
	global ls_use_cmsg

	set cmsg_target ""

	if {$ls_use_cmsg} {
		foreach chan [internalchannels] {
			if {[onchan $target $chan] && [botisop $chan]} {
				set cmsg_target $chan
				break
			}
		}
	}

	return $cmsg_target
}

# sends a notice to specified target
proc ls_putnotc {target text} {
	set cnotice_chan [ls_get_cmsg_chan $target]

	if {$cnotice_chan == ""} {
		putquick "NOTICE $target :$text"
	} else {
		putquick "CNOTICE $target $cnotice_chan :$text"
	}
}

# sends a message to the specified target
proc ls_putmsg {target text} {
	set cprivmsg_chan [ls_get_cmsg_chan $target]

	if {$cprivmsg_chan == ""} {
		putquick "PRIVMSG $target :$text"
	} else {
		putquick "CPRIVMSG $target $cprivmsg_chan :$text"
	}
}

# formats the specified role identifier for output in a message
proc ls_format_role {role} {
	if {$role == "scientist"} {
		return "Mad Scientist"
	} elseif {$role == "investigator"} {
		return "Investigator"
	} elseif {$role == "citizen"} {
		return "Citizen"
	} elseif {$role == "lobby"} {
		return "Lobby"
	} else {
		return "Unknown Role"
	}
}

# formats the specified player name for output in a message (optionally
# revealing that player's role in the game)
proc ls_format_player {chan player {reveal 0}} {
	set no_highlight_player "[string range $player 0 0]\002\002[string range $player 1 end]"

	if {$reveal} {
		return "\002$no_highlight_player\002 ([ls_format_role [ls_get_role $chan $player]])"
	} else {
		return "\002$no_highlight_player\002"
	}
}

# formats a list of player names for output in a message (optionally
# revealing their roles in the game)
proc ls_format_players {chan players {reveal 0}} {
	set hr_list {}

	set players [lsort $players]

	for {set x 0} {$x < [llength $players]} {incr x} {
		if {$x != 0} {
			if {$x == [expr {[llength $players] - 1}]} {
				append hr_list " and "
			} else {
				append hr_list ", "
			}
		}

		append hr_list [ls_format_player $chan [lindex $players $x] $reveal]
	}

	return $hr_list
}

# returns the current state of the game
proc ls_get_gamestate {chan} {
	global ls_gamestate

	if {![info exists ls_gamestate($chan)]} {
		ls_set_gamestate $chan lobby
	}

	return $ls_gamestate($chan)
}

# sets the timeout for the current game state
proc ls_get_gamestate_timeout {chan} {
	global ls_gamestate_timeout

	if {![info exists ls_gamestate_timeout($chan)]} {
		ls_set_gamestate $chan lobby
	}

	return $ls_gamestate_timeout($chan)
}

# returns 1 if the game state delay was exceeded, 0 otherwise
proc ls_gamestate_delay_exceeded {chan} {
	global ls_gamestate_delay

	if {![info exists ls_gamestate_delay($chan)]} {
		ls_set_gamestate $chan lobby
	}

	if {$ls_gamestate_delay($chan) < [clock seconds]} {
		return 1
	} else {
		return 0
	}
}

# sets the game state
proc ls_set_gamestate {chan state} {
	global ls_gamestate ls_gamestate_timeout

	set ls_gamestate($chan) $state

	ls_set_gamestate_timeout $chan -1
	ls_set_gamestate_delay $chan 30

	ls_debug $chan "changed gamestate to $state"
}

# sets the game state timeout (in seconds)
proc ls_set_gamestate_timeout {chan timeout} {
	global ls_gamestate_timeout

	if {$timeout == -1} {
		set ls_gamestate_timeout($chan) -1
	} else {
		set ls_gamestate_timeout($chan) [expr {[clock seconds] + $timeout}]
	}

	ls_debug $chan "changed gamestate timeout to $timeout"
}

# sets the game state delay (in seconds)
proc ls_set_gamestate_delay {chan delay} {
	global ls_gamestate_delay

	set ls_gamestate_delay($chan) [expr {[clock seconds] + $delay}]

	ls_debug $chan "changed gamestate delay to $delay"
}

# returns 1 if the game state timeout was exceeded, 0 otherwise
proc ls_gamestate_timeout_exceeded {chan} {
	set now [clock seconds]
	set timeout [ls_get_gamestate_timeout $chan]

	if {$timeout != -1 && $timeout < $now} {
		return 1
	} else {
		return 0
	}
}

# returns 1 if there's a game in progress, 0 otherwise
proc ls_game_in_progress {chan} {
	if {[ls_get_gamestate $chan] == "lobby"} {
		return 0
	} else {
		return 1
	}
}

# returns the name of the channel the specified nick is playing on
# if the nick isn't playing any games "" is returned instead
proc ls_chan_for_nick {nick} {
	foreach chan [internalchannels] {
		if {[ls_get_role $chan $nick] != ""} {
			return $chan
		}
	}

	return ""
}

proc ls_cmd_add {chan nick} {
	ls_add_player $chan $nick
	ls_advance_state $chan 1
}

proc ls_pub_cmd_labspace {nick host hand chan arg} {
	ls_cmd_add $chan $nick
}

proc ls_pub_cmd_add {nick host hand chan arg} {
	if {[onchan match $chan]} {
		ls_putnotc $nick "Sorry, 'match' is on this channel. You will need to use the alternative set of lobby commands instead (!labspace / !nolabspace)."
		return
	}

	ls_cmd_add $chan $nick
}

proc ls_cmd_remove {chan nick} {
	ls_remove_player $chan $nick
}

proc ls_pub_cmd_nolabspace {nick host hand chan arg} {
	ls_cmd_remove $chan $nick
}

proc ls_pub_cmd_remove {nick host hand chan arg} {
	if {[onchan match $chan]} {
		ls_putnotc $nick "Sorry, 'match' is on this channel. You will need to use the alternative set of lobby commands instead (!labspace / !nolabspace)."
		return
	}

	ls_cmd_remove $chan $nick
}

proc ls_pub_cmd_wait {nick host hand chan arg} {
	if {[ls_game_in_progress $chan]} {
		ls_putnotc $nick "Sorry, there's no lobby at the moment."
	}

	if {[ls_get_role $chan $nick] != "lobby"} {
		ls_putnotc $nick "Sorry, you need to be in the lobby to use this command."
		return
	}

	# extend the timeout / delay for the lobby game state
	ls_set_gamestate_timeout $chan 120
	ls_set_gamestate_delay $chan 45

	ls_putmsg $chan "Lobby timeout was reset."
}

proc ls_cmd_kill {nick victim} {
	global ls_kill_messages

	set chan [ls_chan_for_nick $nick]
	set victim [string trim $victim]

	if {$chan == ""} {
		ls_putnotc $nick "You haven't joined any game lobby."
		return
	}

	if {[ls_get_role $chan $nick] != "scientist"} {
		ls_putnotc $nick "You need to be a scientist to use this command."
		return
	}

	if {[ls_get_gamestate $chan] != "kill"} {
		ls_putnotc $nick "Sorry, you can't use this command right now."
		return
	}

	if {[ls_get_active $chan $nick] != 1} {
		ls_putnotc $nick "Sorry, it's not your turn to choose a victim."
		return
	}

	if {[ls_get_role $chan $victim] == ""} {
		ls_putnotc $nick "Sorry, [ls_format_player $chan $victim] isn't playing the game."
		return
	}

	if {[rand 100] > 85} {
		ls_putmsg $chan "The scientists' attack was not successful tonight. Nobody died."
		ls_post_event $chan kill_failed $nick $victim
	} else {
		ls_devoice_player $chan $victim

		if {[string equal -nocase $victim $nick]} {
			ls_putmsg $chan "[ls_format_player $chan $victim 1] committed suicide."
		} else {
			if {[ls_get_role $chan $victim] == "scientist"} {
				ls_putmsg $chan "[ls_format_player $chan $victim 1] was brutally murdered. Oops."
			} else {
				set index [rand [llength $ls_kill_messages]]
				set format [lindex $ls_kill_messages [rand [llength $ls_kill_messages]]]
				set message [string map [list "%NICK%" [ls_format_player $chan $victim 1]] $format]
				ls_putmsg $chan $message
			}
		}

		ls_remove_player $chan $victim 1
		ls_post_event $chan kill_success $nick $victim
	}

	ls_set_gamestate $chan investigate
	ls_advance_state $chan
}

proc ls_msg_cmd_kill {nick host hand text} {
	ls_putnotc $nick "Note: /msg resets your idle time which might be used by other players to determine your role. You should use /notice instead."
	ls_cmd_kill $nick $text
}

proc ls_notc_cmd_kill {nick host hand text {dest ""}} {
	ls_cmd_kill $nick [join [lrange [split $text] 1 end]]
}

proc ls_cmd_investigate {nick victim} {
	set chan [ls_chan_for_nick $nick]
	set victim [string trim $victim]

	if {$chan == ""} {
		ls_putnotc $nick "You haven't joined any game lobby."
		return
	}

	if {[ls_get_role $chan $nick] != "investigator"} {
		ls_putnotc $nick "You need to be an investigator to use this command."
		return
	}

	if {[ls_get_gamestate $chan] != "investigate"} {
		ls_putnotc $nick "Sorry, you can't use this command right now."
		return
	}

	if {[ls_get_role $chan $victim] == ""} {
		ls_putnotc $nick "Sorry, [ls_format_player $chan $victim] isn't playing the game."
		return
	}

	set investigators [ls_get_players $chan investigator]

	foreach investigator $investigators {
		if {![string equal -nocase $nick $investigator]} {
			ls_putnotc $investigator "Another investigator picked a target."
		}
	}

	if {[rand 100] > 85} {
		ls_putmsg $chan "[ls_format_player $chan $nick]'s fine detective work reveals [ls_format_player $chan $victim]'s role: [ls_format_role [ls_get_role $chan $victim]]"
	}

	if {[string equal -nocase $nick $victim]} {
		ls_putnotc $nick "You're the investigator. Excellent detective work!"
	} else {
		ls_putnotc $nick "[ls_format_player $chan $victim]'s role is: [ls_format_role [ls_get_role $chan $victim]]"
	}
	ls_post_event $chan investigate $nick $victim [ls_get_role $chan $victim]
	ls_set_gamestate $chan vote
	ls_advance_state $chan
}

proc ls_msg_cmd_investigate {nick host hand text} {
	ls_putnotc $nick "Note: /msg resets your idle time which might be used by other players to determine your role. You should use /notice instead."
	ls_cmd_investigate $nick $text
}

proc ls_notc_cmd_investigate {nick host hand text {dest ""}} {
	ls_cmd_investigate $nick [join [lrange [split $text] 1 end]]
}

proc ls_cmd_vote {nick victim} {
	set chan [ls_chan_for_nick $nick]
	set victim [string trim $victim]

	if {$victim == ""} {
		ls_putnotc $nick "Syntax: vote <nick>"
		return
	}

	if {$chan == ""} {
		ls_putnotc $nick "You haven't joined any game lobby."
		return
	}

	if {[ls_get_gamestate $chan] != "vote"} {
		ls_putnotc $nick "Sorry, you can't use this command right now."
		return
	}

	if {[ls_get_role $chan $victim] == ""} {
		ls_putnotc $nick "Sorry, [ls_format_player $chan $victim] isn't playing the game."
		return
	}

	if {[string equal -nocase [ls_get_vote $chan $nick] $victim]} {
		ls_putnotc $nick "You already voted for [ls_format_player $chan $victim]."
		return
	}

	ls_set_vote $chan $nick $victim
	ls_putnotc $nick "Done."

	ls_advance_state $chan
}

proc ls_msg_cmd_vote {nick host hand text} {
	ls_putnotc $nick "Note: /msg resets your idle time which might be used by other players to determine your role. You should use /notice instead."
	ls_cmd_vote $nick $text
}

proc ls_notc_cmd_vote {nick host hand text {dest ""}} {
	ls_cmd_vote $nick [join [lrange [split $text] 1 end]]
}

proc ls_cmd_smite {nick victim} {
	set victim [string trim $victim]
	set chan [ls_chan_for_nick $victim]

	if {$victim == ""} {
		ls_putnotc $nick "Syntax: smite <nick>"
		return
	}

	if {$chan == ""} {
		ls_putnotc $nick "[ls_format_player $chan $victim] isn't in any lobby."
		return
	}

	putmsg $chan "[ls_format_player $chan $victim 1] was struck by lightning."
	ls_remove_player $chan $victim 1
}

proc ls_msg_cmd_smite {nick host hand text} {
	ls_putnotc $nick "Note: /msg resets your idle time which might be used by other players to determine your role. You should use /notice instead."
	ls_cmd_smite $nick $text
}

proc ls_notc_cmd_smite {nick host hand text {dest ""}} {
	ls_cmd_smite $nick [join [lrange [split $text] 1 end]]
}

proc ls_timer_announce_players {arg} {
	set user [lindex $arg 0]
	set chan [lindex $arg 1]

	setctx $user
	ls_announce_players $chan
	flushmode $chan
}

proc ls_announce_players {chan} {
	set new_players [list]

	foreach player [ls_get_players $chan] {
		if {![ls_get_announced $chan $player]} {
			lappend new_players $player
			ls_set_announced $chan $player 1
			ls_voice_player $chan $player
		}
	}

	if {[llength $new_players] > 0} {
		ls_putmsg $chan "[ls_format_players $chan $new_players] joined the game ([llength [ls_get_players $chan]] players in the lobby)."
	}
}

proc ls_add_player {chan nick {forced 0}} {
	set role [ls_get_role $chan $nick]

	if {$role != ""} {
		return
	}

	if {!$forced} {
		if {[ls_game_in_progress $chan]} {
			ls_putnotc $nick "Sorry, you can't join the game right now."
			return
		}

		if {[ls_chan_for_nick $nick] != ""} {
			ls_putnotc $nick "Sorry, you can't play on multiple channels at once."
			return
		}
	}

	ls_set_role $chan $nick lobby
	ls_set_announced $chan $nick $forced

	if {!$forced} {
		ls_set_announced $chan $nick 0
		internaltimer 5 0 ls_timer_announce_players [list [getctx] $chan]
		ls_putnotc $nick "You were added to the lobby."
	} else {
		ls_set_announced $chan $nick 1
		ls_voice_player $chan $nick
	}

	ls_set_gamestate_delay $chan 30
	ls_set_gamestate_timeout $chan 90
}

proc ls_voice_player {chan nick} {
	if {![isvoice $nick $chan]} {
		pushmode $chan +v $nick
	}
}

proc ls_devoice_player {chan nick} {
	if {[isvoice $nick $chan]} {
		pushmode $chan -v $nick
		flushmode $chan
	}
}

proc ls_remove_player {chan nick {forced 0}} {
	set role [ls_get_role $chan $nick]

	if {$role == ""} {
		return
	}

	ls_set_role $chan $nick ""

	pushmode $chan -v $nick
	utimer 1 [list flushmode $chan]

	foreach player [ls_get_players $chan] {
		if {[ls_get_vote $chan $player] == $nick} {
			ls_set_vote $chan $player ""
		}
	}

	if {!$forced} {
		if {[ls_get_announced $chan $nick]} {
			if {[ls_game_in_progress $chan]} {
				ls_putmsg $chan "[ls_format_player $chan $nick] committed suicide. Goodbye, cruel world."
			} else {
				ls_putmsg $chan "[ls_format_player $chan $nick] left the game ([llength [ls_get_players $chan]] players in the lobby)."
			}
		}

		ls_putnotc $nick "You were removed from the lobby."

		ls_set_gamestate_delay $chan 30
		ls_set_gamestate_timeout $chan 90
	}
}

proc ls_get_players {chan {role ""}} {
	set players [list]

	foreach nick [internalchanlist $chan] {
		if {[ls_get_role $chan $nick] == ""} {
			continue
		}

		if {$role == "" || [ls_get_role $chan $nick] == $role} {
			lappend players $nick
		}
	}

	return $players
}

proc ls_get_role {chan nick} {
	return [bncgettag $chan $nick ls_role]
}

proc ls_set_role {chan nick role} {
	bncsettag $chan $nick ls_role $role

	if {$role != "" && $role != "lobby"} {
		ls_putnotc $nick "Your role has been changed to '[ls_format_role $role]'."
	}

	ls_post_event $chan set_role $nick $role
}

proc ls_get_vote {chan nick} {
	return [bncgettag $chan $nick ls_vote]
}

proc ls_set_vote {chan nick vote} {
	if {[string equal -nocase [ls_get_vote $chan $nick] $vote]} {
		return
	}

	if {$vote != ""} {
		set count 0
		foreach player [ls_get_players $chan] {
			if {[string equal -nocase [ls_get_vote $chan $player] $vote]} {
				incr count
			}
		}

		# increase count for this new vote
		incr count

		if {![string equal -nocase $nick $vote]} {
			if {[ls_get_vote $chan $nick] != ""} {
				ls_putmsg $chan "[ls_format_player $chan $nick] changed their vote to [ls_format_player $chan $vote] ($count votes)."
			} else {
				ls_putmsg $chan "[ls_format_player $chan $nick] voted for [ls_format_player $chan $vote] ($count votes)."
			}
		} else {
			ls_putmsg $chan "[ls_format_player $chan $nick] voted for himself. Oops! ($count votes)"
		}

		ls_post_event $chan set_vote $nick $vote
	}

	bncsettag $chan $nick ls_vote $vote
}

proc ls_get_active {chan nick} {
	return [bncgettag $chan $nick ls_active]
}

proc ls_set_active {chan nick active} {
	bncsettag $chan $nick ls_active $active
}

proc ls_get_announced {chan nick} {
	set result [bncgettag $chan $nick ls_announced]

	if {$result == ""} {
		return 0
	}

	return $result
}

proc ls_set_announced {chan nick announced} {
	bncsettag $chan $nick ls_announced $announced
}

proc ls_pick_player {playersVar} {
	upvar $playersVar players

	# work-around for a crash bug in 'rand'
	if {[llength $players] == 0} { return }

	set idx [rand [llength $players]]
	set player [lindex $players $idx]
	set players [lreplace $players $idx $idx]
	return $player
}

proc ls_number_scientists {numPlayers} {
	return [expr {int(ceil(($numPlayers - 2) / 5.0))}]
}

proc ls_start_game {chan} {
	set players [ls_get_players $chan]

	pushmode $chan +m

	# make sure all players are voiced and everyone else is de-voiced
	foreach nick [internalchanlist $chan] {
		if {[lsearch -exact $players $nick] != -1} {
			ls_voice_player $chan $nick
		} else {
			ls_devoice_player $chan $nick
		}
	}

	flushmode $chan

	foreach player $players {
		ls_set_role $chan $player lobby
	}

	ls_putmsg $chan "Starting the game..."
	ls_post_event $chan start_game

	# pick scientists
	set scientists_count 0
	set scientists_needed [ls_number_scientists [llength $players]]
	while {$scientists_count < $scientists_needed} {
		set scientist [ls_pick_player players]
		ls_set_role $chan $scientist scientist
		incr scientists_count
	}

	# notify scientists about each other
	foreach scientist [ls_get_players $chan scientist] {
		foreach scientist_notify [ls_get_players $chan scientist] {
			if {![string equal -nocase $scientist $scientist_notify]} {
				ls_putnotc $scientist_notify "[ls_format_player $chan $scientist] is also a scientist."
			}
		}
	}

	# pick investigator
	set investigator [ls_pick_player players]
	ls_set_role $chan $investigator investigator

	# rest of the players are citizens
	foreach player $players {
		ls_set_role $chan $player citizen
	}

	ls_set_gamestate $chan kill_pending

	utimer 2 [list ls_start_game_delayed $chan]
}

proc ls_start_game_delayed {chan} {
	if {[queuesize all] > 0} {
		utimer 2 [list ls_start_game_delayed $chan]
		return
	}

	set roles [list]
	foreach role [list scientist investigator citizen] {
		lappend roles "[llength [ls_get_players $chan $role]]x [ls_format_role $role]"
	}

	ls_putmsg $chan "Roles have been assigned: [join $roles ", "] - Good luck!"

	ls_set_gamestate $chan kill
	ls_advance_state $chan
}

proc ls_stop_game {chan} {
	ls_set_gamestate $chan lobby

	foreach nick [ls_get_players $chan] {
		ls_remove_player $chan $nick 1
	}

	pushmode $chan -m

	puthelp "PRIVMSG $chan :-hl Labspace"
}

proc ls_pubm_handler {nick uhost hand chan text} {
	global ls_min_players

	set players [ls_get_players $chan]

	if {[ls_get_gamestate $chan] == "lobby" && [llength $players] < $ls_min_players} {
		ls_set_gamestate_delay $chan 90
		ls_set_gamestate_timeout $chan 150
	}
}

proc ls_leave_handler {nick uhost hand chan {msg ""}} {
	if {[ls_get_role $chan $nick] != ""} {
		ls_remove_player $chan $nick
		ls_advance_state $chan
	}
}

proc ls_kick_handler {nick uhost hand chan target reason} {
	if {[ls_get_role $chan $nick] != ""} {
		ls_remove_player $chan $nick
		ls_advance_state $chan
	}
}

proc ls_nick_handler {nick uhost hand chan newnick} {
	foreach player [ls_get_players $chan] {
		if {[ls_get_vote $chan $player] == $nick} {
			ls_set_vote $chan $player $newnick
		}
	}
}

proc ls_timer_advance_state {user} {
	setctx $user

	foreach chan [internalchannels] {
		ls_advance_state $chan 1
		flushmode $chan
	}
}

proc ls_advance_state {chan {delayed 0}} {
	global botnick ls_min_players

	if {$delayed && ![ls_gamestate_delay_exceeded $chan]} {
		return
	}

	ls_set_gamestate_delay $chan 30

	set players [ls_get_players $chan]
	set scientists [ls_get_players $chan scientist]
	set investigators [ls_get_players $chan investigator]

	# game start condition
	if {![ls_game_in_progress $chan]} {
		if {[llength $players] < $ls_min_players} {
			if {[llength $players] > 0} {
				if {[ls_gamestate_timeout_exceeded $chan]} {
					ls_putmsg $chan "Lobby was closed because there aren't enough players."
					ls_stop_game $chan
				} else {
					ls_putmsg $chan "Game will start when there are at least ${ls_min_players} players."
				}
			}
		} else {
			ls_start_game $chan
		}

		return
	}

	# winning condition for scientists
	if {[llength $scientists] >= [expr {[llength $players] - [llength $scientists]}]} {
		ls_putmsg $chan "There are equal to or more scientists than citizens. Science wins again: [ls_format_players $chan $scientists 1]"
		ls_post_event $chan scientists_win

		ls_stop_game $chan

		return
	}

	# winning condition for citizens
	if {[llength $scientists] == 0} {
		ls_putmsg $chan "All scientists have been eliminated. The citizens win this round: [ls_format_players $chan $players 1]"
		ls_post_event $chan citizens_win

		ls_stop_game $chan

		return
	}

	# make sure there's progress towards the game's end
	set state [ls_get_gamestate $chan]
	set timeout [ls_get_gamestate_timeout $chan]

	if {$state == "kill"} {
		if {$timeout == -1} {
			set candidates $scientists
			set active_scientist [ls_pick_player candidates]

			foreach scientist $scientists {
				if {[string equal -nocase $active_scientist $scientist]} {
					ls_set_active $chan $scientist 1
					ls_post_event $chan set_active_scientist $scientist
					ls_putnotc $scientist "It's your turn to select a citizen to kill. Use /notice $botnick kill <nick> to kill someone."
				} else {
					ls_set_active $chan $scientist 0
					ls_putnotc $scientist "[ls_format_player $chan $active_scientist] is choosing a victim."
				}
			}

			if {[llength $scientists] > 1} {
				ls_putmsg $chan "The citizens are asleep while the mad scientists are choosing a target."
			} else {
				ls_putmsg $chan "The citizens are asleep while the mad scientist is choosing a target."
			}

			ls_set_gamestate_timeout $chan 120
		} elseif {[ls_gamestate_timeout_exceeded $chan]} {
			ls_putmsg $chan "The scientists failed to set their alarm clocks. Nobody dies tonight."
			ls_post_event $chan scientists_timeout

			ls_set_gamestate $chan investigate
			ls_advance_state $chan
		} else {
			ls_putmsg $chan "The scientists still need to pick someone to kill."
		}
	}

	if {$state == "investigate"} {
		if {[llength $investigators] == 0} {
			# the investigators are already dead
			ls_set_gamestate $chan vote
			ls_advance_state $chan
			return
		}

		if {$timeout == -1} {
			set candidates $investigators
			set active_investigator [ls_pick_player candidates]

			foreach investigator $investigators {
				if {[string equal -nocase $active_investigator $investigator]} {
					ls_set_active $chan $investigator 1
					ls_post_event $chan set_active_investigator $investigator
					ls_putnotc $investigator "You need to choose someone to investigate: /notice $botnick investigate <nick>"
				} else {
					ls_set_active $chan $investigator 0
					ls_putnotc $investigator "Another investigator is choosing a target."
				}
			}

			if {[llength $investigators] > 1} {
				ls_putmsg $chan "It's now up to the investigators to find the mad scientists."
			} else {
				ls_putmsg $chan "It's now up to the investigator to find the mad scientists."
			}

			ls_set_gamestate_timeout $chan 120
		} elseif {[ls_gamestate_timeout_exceeded $chan]} {
			ls_putmsg $chan "Looks like the investigator is still firmly asleep."
			ls_post_event $chan investigator_timeout

			ls_set_gamestate $chan vote
			ls_advance_state $chan
		} else {
			ls_putmsg $chan "The investigator still needs to do their job."
		}
	}

	if {$state == "vote"} {
		set missing_votes [list]

		foreach player $players {
			if {[ls_get_vote $chan $player] == ""} {
				lappend missing_votes $player
			}
		}

		if {$timeout == -1} {
			foreach player $players {
				ls_set_vote $chan $player ""
			}

			ls_putmsg $chan "It's now up to the citizens to vote who to lynch (via /notice $botnick vote <nick>)."
			ls_set_gamestate_timeout $chan 120
		} elseif {[ls_gamestate_timeout_exceeded $chan] || [llength $missing_votes] == 0} {
			if {[ls_gamestate_timeout_exceeded $chan]} {
			}

			array unset votes

			foreach player $players {
				set vote [ls_get_vote $chan $player]

				if {![info exists votes($player)]} {
					set votes($player) 0
				}

				set real_vote ""
				foreach nick [internalchanlist $chan] {
					if {[string equal -nocase $nick $vote]} {
						set real_vote $nick
						break
					}
				}

				if {$real_vote == ""} {
					continue
				}

				set vote $real_vote

				if {![info exists votes($vote)]} {
					set votes($vote) 0
				}

				incr votes($vote)
			}

			array unset votest_reversed

			foreach {vote count} [array get votes] {
				if {![info exists votes_reversed($count)]} {
					set votes_reversed($count) [list]
				}

				lappend votes_reversed($count) $vote
			}

			set vote_counts [lsort -integer -decreasing [array names votes_reversed]]

			set vote_msg_parts [list]
			foreach vote_count $vote_counts {
				if {$vote_count == 0} {
					continue
				}

				lappend vote_msg_parts "${vote_count}x [ls_format_players $chan $votes_reversed($vote_count)]"
			}
			ls_putmsg $chan "Votes: [join $vote_msg_parts ", "]"

			set candidates $votes_reversed([lindex $vote_counts 0])
			set victim [lindex $candidates [rand [llength $candidates]]]

			ls_debug $chan "lynch candidates: [join $candidates ", "] - picked: $victim"

			ls_devoice_player $chan $victim
			ls_putmsg $chan "[ls_format_player $chan $victim 1] was lynched by the angry mob."
			ls_post_event $chan player_lynched $victim [ls_get_role $chan $victim]
			ls_remove_player $chan $victim 1

			ls_set_gamestate $chan kill
			ls_advance_state $chan
		} elseif {$delayed} {
			ls_putmsg $chan "Some of the citizens still need to vote: [ls_format_players $chan $missing_votes]"
		}
	}
}
