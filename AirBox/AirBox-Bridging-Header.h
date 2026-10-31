//
//  AirBox-Bridging-Header.h
//
//  Swift needs the engine's C entry point, and the group name the engine itself resolved: that one
//  is the group AirBox was actually signed with, which a name derived from the bundle id cannot know
//  once an installer has suffixed it.
//

#import "AirBoxEngine.h"
#import "LCSharedUtils.h"
