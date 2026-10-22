add_library(dolphin SHARED
  DebugLog.h
  DebugLog.mm
  Host.mm
  NetPlay.h
  NetPlay.mm
  HostQueue.h
  HostQueue.mm
)

set_target_properties(dolphin PROPERTIES
  LINK_FLAGS "-Wl,-all_load"
)

target_link_libraries(dolphin
PUBLIC
  common
  core
  uicommon
)
