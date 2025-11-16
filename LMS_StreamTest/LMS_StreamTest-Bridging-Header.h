//
//  LMS_StreamTest-Bridging-Header.h
//  Bridging header for BASS audio library
//
//  Exposes BASS C API to Swift
//

#ifndef LMS_StreamTest_Bridging_Header_h
#define LMS_StreamTest_Bridging_Header_h

// Import Foundation for Objective-C types
#import <Foundation/Foundation.h>

// Import BASS library header
// NOTE: bassflac and bassopus are loaded dynamically via BASS_PluginLoad()
// so we don't need to include their headers here
#import "bass.h"

// Helper for STREAMPROC_PUSH constant (Swift-friendly wrapper)
static inline STREAMPROC* getLyrPlayStreamProcPush(void) {
    return STREAMPROC_PUSH;
}

#endif /* LMS_StreamTest_Bridging_Header_h */
