# LyrPlay CarPlay Implementation - Complete Documentation Plan

## 1. CarPlay Interface Design & User Experience

### **Main Screen Layout Options**

**Option A: Traditional Music App Layout**
```
┌─────────────────────────────────┐
│ LyrPlay                    [⚙️] │
├─────────────────────────────────┤
│ [🎵] Artists                    │
│ [💿] Albums                     │
│ [📋] Playlists                  │  
│ [📻] Radio                      │
│ [🔍] Search                     │
│ [⭐] Favorites                  │
└─────────────────────────────────┘
```

**Option B: LMS-Style Browse Layout**
```
┌─────────────────────────────────┐
│ LyrPlay - Music Library    [⚙️] │
├─────────────────────────────────┤
│ [📁] My Music                   │
│   ├── Artists                   │
│   ├── Albums                    │  
│   ├── Genres                    │
│   └── Years                     │
│ [📋] Playlists                  │
│ [📻] Radio & Apps               │
│ [⭐] Favorites                  │
└─────────────────────────────────┘
```

**Option C: Server-Aware Layout (Recommended)**
```
┌─────────────────────────────────┐
│ LyrPlay - [Server Name]    [⚙️] │
├─────────────────────────────────┤
│ [🎵] Artists                    │
│ [💿] Albums                     │
│ [📋] Playlists                  │
│ [📻] Radio                      │
│ [🔍] Search Library             │
│ ────────────────────────────────│
│ [⚙️] Switch Server              │
└─────────────────────────────────┘
```

### **Navigation Flow Design**

#### **Artists → Albums → Tracks**
```
Artists List          Album List           Track List
┌─────────────┐       ┌─────────────┐       ┌─────────────┐
│ < Back      │       │ < Artists   │       │ < Album     │
│ ─────────── │  →    │ ─────────── │  →    │ ─────────── │
│ Beatles     │       │ Abbey Road  │       │ 1. Come... │
│ Bob Dylan   │       │ Help!       │       │ 2. Someth.. │
│ Pink Floyd  │       │ Let It Be   │       │ 3. Maxwell │
│ ...         │       │ ...         │       │ ...         │
└─────────────┘       └─────────────┘       └─────────────┘
```

#### **Context Actions (Long Press)**
```
Track Context Menu:
┌─────────────────────┐
│ "Come Together"     │
│ ─────────────────── │
│ ▶️ Play Now          │
│ ➕ Add to Queue      │  
│ 📋 Add to Playlist   │
│ ⭐ Add to Favorites  │
│ ℹ️ Track Info        │
└─────────────────────┘
```

### **Search Interface Design**

**Voice Search Integration:**
```
┌─────────────────────────────────┐
│ Search Results for "Beatles"    │
├─────────────────────────────────┤
│ 🎵 Artists (1)                  │
│   The Beatles                   │ 
│ 💿 Albums (12)                  │
│   Abbey Road, Help!, ...        │
│ 🎼 Tracks (156)                 │
│   Come Together, Hey Jude...    │
└─────────────────────────────────┘
```

**Keyboard Search:**
```
┌─────────────────────────────────┐
│ [Search: "bea_"]           [❌] │
├─────────────────────────────────┤
│ Recent Searches:                │
│ • Beatles                       │
│ • Beach Boys                    │
│ ─────────────────────────────── │
│ Suggestions:                    │
│ • Beatles (Artist)              │  
│ • Beautiful Boy (Track)         │
└─────────────────────────────────┘
```

## 2. Technical Architecture Documentation

### **System Architecture Overview**

```
┌─────────────────┐    JSON-RPC    ┌─────────────────┐
│   CarPlay UI    │ ←────────────→ │  LMS Server     │
│                 │                │                 │
│ MPPlayable-     │                │ artists/albums/ │
│ Content APIs    │                │ playlists/etc   │
└─────────────────┘                └─────────────────┘
         │                                  
         ▼                                  
┌─────────────────┐    SlimProto   ┌─────────────────┐
│   LyrPlay       │ ←────────────→ │  LMS Server     │
│   Audio Stack   │                │                 │
│ SlimProto/      │                │ Audio Streaming │
│ StreamingKit    │                │ & Control       │
└─────────────────┘                └─────────────────┘
```

### **Component Architecture**

#### **CarPlayManager (New)**
```swift
class CarPlayManager: NSObject {
    // MARK: - Dependencies
    private let jsonRpcClient: LMSJSONRPCClient
    private let settingsManager: SettingsManager  
    private let slimProtoCoordinator: SlimProtoCoordinator
    
    // MARK: - CarPlay State
    private var contentItems: [String: MPContentItem] = [:]
    private var currentPlayerID: String?
    
    // MARK: - Public Interface
    func initialize()
    func handleServerChange()
    func refreshContent()
}

extension CarPlayManager: MPPlayableContentDataSource {
    func numberOfChildItems(at indexPath: IndexPath) -> Int
    func contentItem(at indexPath: IndexPath) -> MPContentItem?
    func beginLoadingChildItems(at indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void)
}

extension CarPlayManager: MPPlayableContentDelegate {
    func playableContentManager(_ contentManager: MPPlayableContentManager, initiatePlaybackOfContentItemAt indexPath: IndexPath, completionHandler: @escaping (Error?) -> Void)
}
```

#### **LMSJSONRPCClient (New)**
```swift
class LMSJSONRPCClient {
    struct JSONRPCRequest {
        let id: Int
        let method: String = "slim.request"
        let params: [Any]
    }
    
    struct JSONRPCResponse<T: Codable> {
        let id: Int
        let result: T?
        let error: JSONRPCError?
    }
    
    // Core API Methods
    func getArtists(start: Int, count: Int, libraryID: String?) async throws -> ArtistsResponse
    func getAlbums(start: Int, count: Int, artistID: String?, libraryID: String?) async throws -> AlbumsResponse  
    func getPlaylists(start: Int, count: Int) async throws -> PlaylistsResponse
    func getTracks(albumID: String?, playlistID: String?, start: Int, count: Int) async throws -> TracksResponse
    func search(query: String, types: [SearchType]) async throws -> SearchResponse
    
    // Playback Commands  
    func playItem(playerID: String, itemType: ItemType, itemID: String) async throws
    func addToQueue(playerID: String, itemType: ItemType, itemID: String) async throws
}
```

### **Data Models**

#### **Response Models**
```swift
struct ArtistsResponse: Codable {
    let count: Int
    let artists_loop: [Artist]
}

struct Artist: Codable {
    let id: String
    let artist: String
    let textkey: String?
}

struct AlbumsResponse: Codable {
    let count: Int  
    let albums_loop: [Album]
}

struct Album: Codable {
    let id: String
    let album: String
    let artist: String?
    let artist_id: String?
    let year: Int?
    let artwork_url: String?
}

struct PlaylistsResponse: Codable {
    let count: Int
    let playlists_loop: [Playlist]
}

struct Playlist: Codable {
    let id: String
    let playlist: String
    let url: String?
}

struct TracksResponse: Codable {
    let count: Int
    let tracks_loop: [Track]
}

struct Track: Codable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let duration: Double?
    let tracknum: String?
}
```

## 3. Implementation Plan - Detailed Phases

### **Phase 1: Foundation & JSON-RPC Client (Week 1)**

#### **Day 1-2: Project Setup**
- Add CarPlay entitlements to Info.plist
- Add MediaPlayer framework dependency
- Create base CarPlay manager structure
- Set up JSON-RPC client architecture

#### **Day 3-4: JSON-RPC Implementation**  
- Implement core HTTP client with URLSession
- Create request/response models
- Implement basic commands: artists, albums, playlists
- Add error handling and timeouts

#### **Day 5-7: Testing & Validation**
- Test JSON-RPC commands against real LMS server
- Validate response parsing
- Add logging and debugging tools
- Create unit tests for client

**Deliverables:**
- ✅ **COMPLETED**: Working LMSJSONRPCClient with Material skin commands
- ✅ **COMPLETED**: Basic CarPlay project structure
- ✅ **COMPLETED**: JSON-RPC functionality with proper command formats
- ✅ **COMPLETED**: Data model parsing (Int IDs, titles_loop mapping)
- ✅ **COMPLETED**: Error handling and logging

### **Phase 2: CarPlay Browse Interface (Week 2)**

#### **Day 8-10: Content Tree Structure**
- Implement MPPlayableContentDataSource
- Create content item hierarchy (Artists → Albums → Tracks)
- Handle content loading and caching
- Implement proper content identifiers

#### **Day 11-12: UI Templates**
- Configure CarPlay tab structure
- Implement list templates for each content type
- Add proper icons and metadata display
- Handle empty states and loading states

#### **Day 13-14: Navigation & State**  
- Implement drill-down navigation
- Add breadcrumb navigation support
- Handle back button functionality  
- Test content browsing flow

**Deliverables:**
- ✅ **COMPLETED**: Working CarPlay browse interface
- ✅ **COMPLETED**: Artists/Albums/Playlists tabs functional  
- ✅ **COMPLETED**: Artists → Albums → Tracks drill-down navigation
- ⚠️ **PARTIAL**: Albums tab (shows all albums, no drill-down implemented yet)
- ⚠️ **PARTIAL**: Playlists tab (shows playlists, no tracks view implemented yet)
- ✅ **COMPLETED**: Content loading with proper async handling

### **Phase 3: Playback Integration (Week 3)**

#### **Day 15-16: Playback Commands**
- Implement MPPlayableContentDelegate
- Connect CarPlay play actions to SlimProto
- Handle different play modes (play now, add to queue)
- Test basic playback functionality

#### **Day 17-18: Now Playing Integration**
- Ensure existing NowPlayingManager works in CarPlay
- Verify control center integration
- Test playback controls (play/pause/skip)
- Handle audio session management

#### **Day 19-21: Queue Management**
- Implement queue viewing in CarPlay
- Add queue manipulation (reorder, remove)
- Handle shuffle and repeat modes
- Test complex playback scenarios

**Deliverables:**
- ✅ **COMPLETED**: Track playback functionality (Artists → Albums → Tracks path)
- ✅ **COMPLETED**: Unified queue management (CarPlay ↔ Material interface sync)
- ✅ **COMPLETED**: JSON-RPC playback commands (`playlistcontrol cmd:load`)
- ❌ **NOT IMPLEMENTED**: Album playback (play entire album)
- ❌ **NOT IMPLEMENTED**: Playlist playback (play entire playlist)  
- ⚠️ **iOS 18 ISSUE**: Now Playing screen (known iOS bug, not our code)
- ❌ **NOT IMPLEMENTED**: Queue viewing/management within CarPlay

### **Phase 4: Advanced Features (Week 4)**

#### **Day 22-23: Search Implementation**  
- Add CarPlay search interface
- Implement voice search support
- Create search result categorization
- Test search functionality

#### **Day 24-25: Server Management**
- Add server switching within CarPlay
- Handle connection state changes  
- Implement backup server support
- Add connection error handling

#### **Day 26-28: Polish & Testing**
- Add comprehensive error handling
- Implement proper loading states
- Add user preferences for CarPlay
- Extensive testing across different scenarios
- Performance optimization

**Deliverables:**
- ✅ Complete CarPlay implementation
- ✅ Search and server management
- ✅ Production-ready code quality

## 4. JSON-RPC Command Reference

### **Core Browse Commands**

#### **Artists List**
```json
{
  "id": 1,
  "method": "slim.request", 
  "params": ["player_id", ["artists", 0, 100, "tags:s", "include_online_only_artists:1"]]
}
```

#### **Albums by Artist**  
```json
{
  "id": 2,
  "method": "slim.request",
  "params": ["player_id", ["albums", 0, 100, "artist_id:123", "tags:jlays", "sort:album"]]
}
```

#### **Album Tracks**
```json
{
  "id": 3, 
  "method": "slim.request",
  "params": ["player_id", ["tracks", 0, 100, "album_id:456", "tags:gladiqrRtueJINpsy", "sort:tracknum"]]
}
```

#### **All Playlists**
```json
{
  "id": 4,
  "method": "slim.request", 
  "params": ["", ["playlists", 0, 100, "tags:su"]]
}
```

#### **Playlist Contents**
```json
{
  "id": 5,
  "method": "slim.request",
  "params": ["player_id", ["playlists", "tracks", 0, 100, "playlist_id", "tags:gald"]]
}
```

### **Playback Commands**

#### **Play Album**
```json
{
  "id": 6,
  "method": "slim.request",
  "params": ["player_id", ["playlist", "play", "album_id:123"]]
}
```

#### **Add Track to Queue**  
```json
{
  "id": 7,
  "method": "slim.request", 
  "params": ["player_id", ["playlist", "add", "track_id:456"]]
}
```

### **Search Commands**
```json
{
  "id": 8,
  "method": "slim.request",
  "params": ["player_id", ["search", 0, 50, "term:beatles", "want_url:1"]]
}
```

## 5. User Interface Specifications

### **CarPlay Screen Layouts**

#### **Main Browse Screen (Recommended Design)**
```
╔═══════════════════════════════════╗
║ 🎵 LyrPlay - Home Server     [⚙️] ║  
╠═══════════════════════════════════╣
║                                   ║
║ [🎵] Artists (1,247)              ║  
║ [💿] Albums (856)                 ║
║ [📋] Playlists (23)               ║
║ [📻] Radio (15 stations)          ║
║ ─────────────────────────────────  ║  
║ [🔍] Search Music                 ║
║ [⭐] Favorites                    ║
║                                   ║
╚═══════════════════════════════════╝
```

#### **Artists List View**
```
╔═══════════════════════════════════╗
║ < Back to Library          [A-Z] ║
╠═══════════════════════════════════╣
║                                   ║
║ 📀 The Beatles            [▶️][+] ║
║ 🎸 Bob Dylan              [▶️][+] ║  
║ 🌈 Pink Floyd             [▶️][+] ║
║ 🎹 Elton John             [▶️][+] ║
║ 🎤 David Bowie            [▶️][+] ║
║ 🎺 Miles Davis            [▶️][+] ║
║                                   ║
║ [Load More...]                    ║
╚═══════════════════════════════════╝
```

#### **Album Detail View**
```  
╔═══════════════════════════════════╗
║ < Back to Albums          [▶️][+] ║
╠═══════════════════════════════════╣
║ 💿 Abbey Road                     ║
║    The Beatles • 1969             ║
║ ─────────────────────────────────  ║
║ 1. Come Together           2:58   ║
║ 2. Something               3:03   ║  
║ 3. Maxwell's Silver...     3:28   ║
║ 4. Oh! Darling             3:26   ║
║ 5. Octopus's Garden        2:51   ║
║ 6. I Want You (She's...    7:47   ║
║                                   ║
╚═══════════════════════════════════╝
```

### **Context Menu Actions**

#### **Track Context Menu**
```
╔═══════════════════════════════════╗
║ "Come Together" - The Beatles     ║  
╠═══════════════════════════════════╣
║ ▶️ Play Now                        ║
║ ⏭️ Play Next                       ║
║ ➕ Add to Queue                    ║
║ 📋 Add to Playlist                ║
║ ⭐ Add to Favorites               ║  
║ ℹ️ Track Information              ║
╚═══════════════════════════════════╝
```

#### **Album Context Menu**
```
╔═══════════════════════════════════╗ 
║ "Abbey Road" - The Beatles        ║
╠═══════════════════════════════════╣
║ ▶️ Play Album                      ║
║ 🔀 Shuffle Album                  ║
║ ➕ Add Album to Queue             ║
║ ⭐ Add Album to Favorites         ║
║ 👤 View Artist                   ║
║ ℹ️ Album Information              ║  
╚═══════════════════════════════════╝
```

## 6. Error Handling & Edge Cases

### **Connection Scenarios**
- Server unreachable → Show "Server Unavailable" with retry option
- Network timeout → Show "Connection Timeout" with settings option  
- Invalid credentials → Redirect to server settings
- Server switching → Show loading state, maintain queue if possible

### **Content Scenarios**  
- Empty library → Show "No Music Found" with rescan option
- Large libraries → Implement pagination with "Load More" buttons
- Missing artwork → Use default placeholder images
- Corrupt metadata → Show "Unknown Artist/Album" gracefully

### **Playback Scenarios**
- Track unavailable → Skip to next track, show notification
- Codec not supported → Fall back to transcoded version
- Queue empty → Show "Queue Empty" in Now Playing
- SlimProto disconnected → Show connection status, attempt reconnect

## 7. Development Considerations

### **CarPlay Entitlements Required**
```xml
<key>com.apple.developer.carplay-audio</key>
<true/>
```

### **Info.plist CarPlay Configuration**
```xml
<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>audio-playback</string>
</array>

<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
</array>
```

### **Framework Dependencies**
- **MediaPlayer.framework** - CarPlay APIs
- **AVFoundation.framework** - Audio session management (already included)
- **Foundation.framework** - JSON-RPC networking

### **Testing Strategy**
- **CarPlay Simulator** - Initial development and basic testing
- **Physical CarPlay Device** - Essential for final validation
- **Multiple LMS Servers** - Test server switching and different configurations
- **Large Libraries** - Performance testing with thousands of albums
- **Network Conditions** - Test poor connectivity and timeouts

### **Performance Considerations**
- **Lazy Loading** - Load content items only when needed
- **Image Caching** - Cache album artwork for better performance
- **Request Batching** - Combine multiple JSON-RPC calls when possible
- **Background Loading** - Pre-load content during idle times
- **Memory Management** - Release unused content items to conserve memory

### **User Experience Principles**
- **Fast Response** - All CarPlay interactions should feel instant
- **Clear Hierarchy** - Logical navigation that matches user expectations
- **Minimal Interaction** - Reduce required taps/swipes for common actions
- **Voice Integration** - Support Siri for hands-free operation
- **Error Recovery** - Always provide clear path forward from error states

## 8. Future Enhancement Opportunities

### **Phase 5 Potential Features**
- **Offline Mode** - Cache favorite albums for offline CarPlay use
- **Voice Commands** - "Hey Siri, play my Jazz playlist in LyrPlay"
- **Smart Playlists** - Recently played, most played, etc.
- **Multi-Server** - Quick server switching within CarPlay
- **Advanced Search** - Filter by genre, year, rating
- **Social Features** - Recently played by other users
- **Car-Specific** - Different preferences per connected car

### **Integration Opportunities**
- **Siri Shortcuts** - "Play my morning playlist"
- **iOS Shortcuts** - Complex automation workflows
- **Widget Support** - Home screen controls
- **Watch App** - Apple Watch remote control
- **AirPlay** - Multi-room audio integration

---

## **CURRENT IMPLEMENTATION STATUS** 🚗

### **✅ COMPLETED FEATURES**

#### **Core Foundation (Phase 1) - COMPLETE**
- ✅ CarPlay entitlements configured (`com.apple.developer.playable-content`)
- ✅ LMSJSONRPCClient with Material skin command compatibility
- ✅ Data models with proper JSON parsing (Int IDs, titles_loop mapping)
- ✅ Comprehensive error handling and logging
- ✅ Player ID integration (MAC address from SettingsManager)

#### **Browse Interface (Phase 2) - MOSTLY COMPLETE**
- ✅ **Artists → Albums → Tracks** full drill-down navigation
- ✅ All three main tabs displayed (Artists, Albums, Playlists)
- ✅ Content loading with async/await pattern
- ✅ Proper content item creation for CarPlay
- ✅ Error handling and completion callbacks

#### **Track Playback (Phase 3) - CORE COMPLETE**
- ✅ **Track selection and playback** functional
- ✅ **Unified queue management** (CarPlay ↔ Material interface synchronization)
- ✅ Correct JSON-RPC commands (`["playlistcontrol", "cmd:load", "track_id:123"]`)
- ✅ Audio streaming integration (LMS → SlimProto → StreamingKit)
- ✅ Lock screen integration working

### **⚠️ KNOWN ISSUES**
- **iOS 18 CarPlay Bug**: "Problem loading this content" after successful playback
  - **Status**: Known Apple system bug affecting multiple major apps
  - **Impact**: Audio works perfectly, CarPlay UI fails to transition to Now Playing
  - **Workaround**: None - waiting for Apple iOS updates

### **❌ NOT YET IMPLEMENTED**

#### **Missing Browse Paths**
- ❌ **Albums Tab → Tracks**: Direct album browsing (bypassing artist selection)
- ❌ **Playlists → Tracks**: Playlist content viewing
- ❌ **Album/Playlist Playback**: Play entire albums/playlists (not just individual tracks)

#### **Advanced Features (Phase 4)**
- ❌ **Search Interface**: Voice and keyboard search
- ❌ **Queue Management**: View/edit queue within CarPlay
- ❌ **Server Switching**: Change servers from CarPlay
- ❌ **Context Actions**: Long-press menus for albums/playlists

### **🎯 IMMEDIATE NEXT PRIORITIES**

#### **High Priority (Expand Browse Interface)**
1. **Implement Albums → Tracks navigation**
   - Allow direct album selection from Albums tab
   - Show track listing for selected albums
   - Enable track selection and playback

2. **Implement Playlists → Tracks navigation** 
   - Show playlist contents when selected
   - Enable playlist track playback

3. **Add Album/Playlist Playback**
   - "Play Album" functionality
   - "Play Playlist" functionality  
   - Queue entire collections, not just individual tracks

#### **Medium Priority (Enhanced Functionality)**
4. **Improve Content Item Configuration**
   - Albums should be playable containers (play album + view tracks)
   - Playlists should be playable containers (play playlist + view tracks)
   - Add context menu support

5. **Add Search Interface (Phase 4)**
   - Implement CarPlay search tab
   - Voice search integration
   - Search result categorization

#### **Lower Priority (Advanced Features)**
6. **Queue Management Within CarPlay**
7. **Server Switching Interface**
8. **Error Recovery and State Management**

### **🧪 TESTING STATUS**
- ✅ **Simulator Testing**: Basic functionality verified (with iOS 18 UI bugs)
- 🔄 **Real CarPlay Hardware**: Testing in progress
- ❌ **Production Testing**: Not yet conducted with multiple users

### **📊 COMPLETION PERCENTAGE**
- **Phase 1 (Foundation)**: 100% ✅
- **Phase 2 (Browse Interface)**: 70% (missing direct album/playlist browsing)
- **Phase 3 (Playback)**: 60% (track playback works, missing album/playlist playback)
- **Phase 4 (Advanced Features)**: 0%

**Overall Implementation**: ~65% Complete

---

## Summary

This CarPlay implementation will transform LyrPlay from a mobile-only LMS client into a comprehensive music solution that works seamlessly in both handheld and automotive environments. The dual-path architecture (JSON-RPC for browsing, SlimProto for playback) ensures optimal performance while maintaining full LMS compatibility.

**Estimated Timeline:** 4 weeks for full implementation  
**Key Benefits:** Native CarPlay interface, voice search, server flexibility, familiar UX  
**Technical Risk:** Medium - well-documented APIs with proven JSON-RPC commands from Material skin

The plan provides a clear roadmap from initial setup through production deployment, with detailed specifications for both the user interface and technical implementation.