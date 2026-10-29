// File: URLCredentialMaskingTests.swift
// Stream, artwork and Material URLs carry the LMS password (bd cpb7); every
// log line masks it, since users post the diagnostic log on GitHub.
import Testing
import Foundation
@testable import LMS_StreamTest

struct URLCredentialMaskingTests {
    @Test func masksUserAndPassword() {
        #expect("http://eric:secret@192.168.1.8:9000/stream.mp3?player=aa".maskingURLCredentials
                == "http://***:***@192.168.1.8:9000/stream.mp3?player=aa")
        #expect("https://u:p@lms.example.com/material/".maskingURLCredentials
                == "https://***:***@lms.example.com/material/")
    }

    @Test func masksPasswordsWithSpecialCharacters() {
        // As injectCredentialsIntoURL builds them: URLComponents percent-encodes the password.
        var components = URLComponents(string: "http://192.168.1.8:9000/music/12/cover.jpg")!
        components.user = "eric"
        components.password = "p@ss:w/rd?#"
        let masked = components.url!.absoluteString.maskingURLCredentials
        #expect(masked == "http://***:***@192.168.1.8:9000/music/12/cover.jpg")
        #expect(!masked.contains("ss"))
    }

    @Test func leavesURLsWithoutCredentialsAlone() {
        let urls = ["http://192.168.1.8:9000/stream.mp3?player=aa:bb:cc",
                    "https://www.radioparadise.com/graphics/logo.png",
                    "http://host:9000/path/with@sign",
                    "lyrplay://settings",
                    ""]
        for url in urls {
            #expect(url.maskingURLCredentials == url)
        }
    }
}
