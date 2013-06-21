package require eggdrop
package require Tcl 8.4
package provide sbnc 1.1

bind nick - * bnctagnickchange
bind part - * bnctagkill
bind sign - * bnctagkill

proc setctx args {}
proc getctx args { return "eggdrop" }

if {[info commands _queuesize] eq ""} {
  rename queuesize _queuesize
  proc queuesize {args} {
    if {[llength $args] && [lindex $args 0] eq "all"} {
      set args ""
    }
   uplevel 1 _queuesize $args
  }
}     

proc internaltimer {delay repeat args} {
  utimer $delay $args
  if {$repeat} {
    utimer $delay [concat [list internaltimer $delay $repeat] $args]
  }
}

proc internalchannels {} {
  channels
}

proc internalchanlist {chan} {
  chanlist $chan
}

proc noargs {cmd args} {
  uplevel 1 $cmd
}

proc internalbind {event args} {
  if {$event ne "svrdisconnect"} {
    error "Unsupported internalbind event: $event"
  }
  bind evnt - disconnect-server [list noargs $args]
}

proc bncsettag {chan nick key value} {
  global bnctags

  set bnctags($nick,$chan,$key) $value
}

proc bncgettag {chan nick key} {
  global bnctags

  if {![info exists bnctags($nick,$chan,$key)]} {
    return ""
  }

  return $bnctags($nick,$chan,$key)
}

proc bnctagnickchange {nick host hand chan newnick} {
  global bnctags

  foreach key [array names bnctags $nick,$chan,*] {
    set newkey $newnick,[join [lrange [split $key ,] 1 end] ,]
    set bnctags($newkey) $bnctags($key)
    unset bnctags($key)
  }
}

proc bnctagkill {nick host hand chan args} {
  global bnctags

  foreach key [array names bnctags $nick,$chan,*] {
    unset bnctags($key)
  }
}

if {![info exists ::bnctags]} {
  array set ::bnctags {}
}
