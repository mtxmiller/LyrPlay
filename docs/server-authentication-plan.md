# LMS Server Authentication Implementation Plan

## Summary: Authentication Architecture Deep Dive

Based on comprehensive study of **squeezelite source code** and **LMS server source code**, here's the complete authentication architecture:

---

## **CRITICAL FINDING: How Audio Stream Authentication ACTUALLY Works**

### **Squeezelite Does NOT Handle Authentication!**

After examining `squeezelite/stream.c` and `squeezelite/slimproto.c`:
- **Squeezelite has ZERO authentication code**
- No username/password handling
- No Authorization header construction
- The HTTP headers are constructed **BY THE SERVER** and passed to the player

### **The LMS Server Constructs the Auth Header**

From `slimserver/Slim/Player/Protocols/HTTP.pm` line 956-957:
```perl
if (defined($user) && defined($password)) {
    $request .= $CRLF . "Authorization: Basic " . MIME::Base64::encode_base64($user . ":" . $password,'');
}
```

### **The Complete Flow:**

1. **SlimProto 'strm' Command** (`slimproto.c` line 346-378):
   ```c
   unsigned header_len = len - sizeof(struct strm_packet);
   char *header = (char *)(pkt + sizeof(struct strm_packet));
   stream_sock(ip, port, strm->flags & 0x20,
               header, header_len, strm->threshold * 1024, autostart >= 2);
   ```
   - Server sends complete HTTP request header in the `strm` packet
   - This header INCLUDES the `Authorization: Basic ...` line if server needs auth
   - Player receives this as `header` string

2. **Squeezelite Sends the Header As-Is** (`stream.c` line 168-200):
   ```c
   static bool send_header(void) {
       char *ptr = stream.header;
       int len = stream.header_len;
       // ... sends header verbatim to HTTP server
   }
   ```
   - Squeezelite just sends whatever header the server provided
   - No modification, no auth handling needed in player

3. **For LyrPlay**:
   - **Audio streams are ALREADY WORKING with secured servers!**
   - The server includes auth in the HTTP header it sends us via SlimProto
   - We already forward this header correctly in our stream handling
   - **NO CODE CHANGES NEEDED for audio stream authentication** ✅

---

## **What DOES Need Client-Side Authentication:**

### 1. **SlimProto Connection (Port 3483):**
   - **Does NOT require authentication** ✅
   - Binary protocol for player control
   - Always works, even on secured servers

### 2. **Web UI Access (Material Interface):**
   - **REQUIRES authentication** when server has `authorize` enabled
   - Client-initiated HTTP/HTTPS requests to load Material
   - **WE must add `Authorization` header**

### 3. **JSON-RPC Commands:**
   - **REQUIRES authentication** when server has `authorize` enabled
   - Client-initiated HTTP POST requests to `/jsonrpc.js`
   - **WE must add `Authorization` header**
   - Examples: Server time sync, playlist queries, volume control

---

## **HTTP Basic Authentication Details**

From `Slim/Web/HTTP.pm`:
- Header format: `Authorization: Basic base64(username:password)`
- Server validates:
  - Username matches stored username (clear text)
  - Password is SHA1-base64 hashed and compared
- Returns **401 Unauthorized** with `WWW-Authenticate` header if auth fails
- Once validated, all subsequent requests need the same header

---

## **Implementation Plan for LyrPlay**

### **Scope Clarification** ⚠️

Based on source code analysis:
- ✅ **Audio streaming**: Already works with secured servers (no changes needed)
- ❌ **WebView (Material UI)**: Needs authentication implementation
- ❌ **JSON-RPC requests**: Needs authentication implementation

---

### **Phase 1: Data Model** (SettingsManager.swift)

Add authentication properties and helper method:

```swift
// Published properties for UI binding
@Published var serverUsername: String = ""
@Published var serverPassword: String = ""
@Published var backupServerUsername: String = ""
@Published var backupServerPassword: String = ""

// UserDefaults keys
private enum Keys {
    static let serverUsername = "ServerUsername"
    static let serverPassword = "ServerPassword"
    static let backupServerUsername = "BackupServerUsername"
    static let backupServerPassword = "BackupServerPassword"
}

// Computed property for active server credentials
var activeServerUsername: String {
    return currentActiveServer == .primary ? serverUsername : backupServerUsername
}

var activeServerPassword: String {
    return currentActiveServer == .primary ? serverPassword : backupServerPassword
}

// HTTP Basic Auth header generator
var authorizationHeader: String? {
    let username = activeServerUsername
    let password = activeServerPassword

    guard !username.isEmpty else { return nil }

    let credentials = "\(username):\(password)"
    let base64 = Data(credentials.utf8).base64EncodedString()
    return "Basic \(base64)"
}
```

**Persistence:**
- Add save/load logic in `saveSettings()` and `loadSettings()`
- Store in UserDefaults (encrypted by iOS)
- Future enhancement: Move to Keychain for production apps

---

### **Phase 2: UI Updates**

#### **Onboarding Flow** (OnboardingViews.swift - ServerSetupView)

Add authentication section after server address fields:

```swift
// Authentication Section (Optional)
Section(header: Text("Server Authentication").foregroundColor(.white)) {
    VStack(spacing: 20) {
        Toggle(isOn: $requiresAuth) {
            Text("Server Requires Authentication")
                .font(.headline)
                .foregroundColor(.white)
        }

        if requiresAuth {
            FormField(
                title: "Username",
                placeholder: "admin",
                text: $username
            )

            SecureField("Password", text: $password)
                .textFieldStyle(CustomTextFieldStyle())
                .padding(.top, 8)

            Text("Only required if your LMS server has authentication enabled in Settings → Security.")
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}
.padding(.top)
```

#### **Settings Views** (SettingsView.swift)

**ServerConfigView** - Add after server address section:

```swift
Section(header: Text("Authentication (Optional)")) {
    TextField("Username", text: $username)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .autocapitalization(.none)
        .disableAutocorrection(true)
        .onChange(of: username) { _ in hasChanges = true }

    SecureField("Password", text: $password)
        .textFieldStyle(RoundedBorderTextFieldStyle())
        .onChange(of: password) { _ in hasChanges = true }

    Text("Only required if your LMS server has authentication enabled. Leave blank for servers without security.")
        .font(.caption)
        .foregroundColor(.secondary)
}
```

**BackupServerConfigView** - Add identical authentication section

---

### **Phase 3: WebView Authentication** (ContentView.swift)

Implement WKNavigationDelegate to inject auth headers:

```swift
extension ContentView: WKNavigationDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        // Check if we have authentication credentials
        if let authHeader = SettingsManager.shared.authorizationHeader,
           let url = navigationAction.request.url {

            // Create new request with auth header
            var request = URLRequest(url: url)
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")

            // Copy other headers from original request
            navigationAction.request.allHTTPHeaderFields?.forEach { key, value in
                if key != "Authorization" {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }

            // Load the authenticated request
            webView.load(request)
            decisionHandler(.cancel)
            return
        }

        // No auth needed, proceed normally
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        // Check for 401 authentication errors
        if let urlError = error as? URLError,
           let response = urlError.response as? HTTPURLResponse,
           response.statusCode == 401 {

            // Show user-friendly error
            os_log(.error, log: logger, "❌ Server requires authentication - check username/password in Settings")

            // TODO: Show alert prompting user to add credentials in Settings
        }
    }
}
```

---

### **Phase 4: JSON-RPC Authentication** (SlimProtoCoordinator.swift)

Update all JSON-RPC request creation to include auth header:

**Example locations to update:**
- `syncServerTime()` - Server time synchronization
- `sendLockScreenCommand()` - Lock screen play/pause
- Any other JSON-RPC calls to `/jsonrpc.js`

```swift
// Example: syncServerTime() modification
private func syncServerTime() async {
    let url = URL(string: "http://\(settings.activeServerHost):\(settings.activeServerWebPort)/jsonrpc.js")!

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    // ADD AUTHENTICATION HEADER
    if let authHeader = settings.authorizationHeader {
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }

    let jsonData = try! JSONEncoder().encode(rpcRequest)
    request.httpBody = jsonData

    // ... rest of method
}
```

**Search for all occurrences of:**
- `/jsonrpc.js` URL construction
- JSON-RPC POST requests
- Add auth header to each

---

### **Phase 5: Connection Testing** (SettingsManager.swift)

Update `testHTTPConnection()` to include auth:

```swift
private func testHTTPConnection(host: String, port: Int) async -> PortTestResult {
    guard let url = URL(string: "http://\(host):\(port)/") else {
        return .failure("Invalid URL format")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"
    request.setValue(customUserAgent, forHTTPHeaderField: "User-Agent")

    // ADD AUTHENTICATION HEADER IF AVAILABLE
    if let authHeader = authorizationHeader {
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")
    }

    request.timeoutInterval = connectionTimeout

    do {
        let (_, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 401 {
                return .failure("Authentication required - check username/password")
            }
            if httpResponse.statusCode < 400 {
                os_log(.info, log: logger, "HTTP test successful - Status: %d", httpResponse.statusCode)
                return .success
            } else {
                return .failure("HTTP Error \(httpResponse.statusCode)")
            }
        }
        // ... rest of method
    }
}
```

---

### **Phase 6: Error Handling & UX Polish**

#### **401 Detection in WebView:**
- Implement `WKNavigationDelegate.webView(_:didFailProvisionalNavigation:withError:)`
- Check for HTTP 401 status code
- Show alert: "Server requires authentication. Please add credentials in Settings → Server Configuration."
- Provide button to navigate directly to settings

#### **401 Detection in JSON-RPC:**
- Check HTTP response status codes in all JSON-RPC methods
- Log authentication failures
- Consider showing in-app notification for auth issues

#### **Security Warning:**
- When credentials are entered over HTTP (not HTTPS), show warning:
  - "⚠️ Your server is using HTTP without encryption. Credentials are sent as base64-encoded text. Consider enabling HTTPS for better security."

#### **Credential Validation:**
- Empty username = no authentication (current behavior)
- Non-empty username = authentication required
- Test button validates credentials work before saving

---

## **Implementation Summary**

### **Files to Modify:**

| File | Changes | Complexity |
|------|---------|------------|
| `SettingsManager.swift` | Add username/password properties, auth header generator, persistence | Medium |
| `OnboardingViews.swift` | Add auth fields to ServerSetupView | Low |
| `SettingsView.swift` | Add auth fields to ServerConfigView and BackupServerConfigView | Low |
| `ContentView.swift` | Implement WKNavigationDelegate for WebView auth header injection | Medium |
| `SlimProtoCoordinator.swift` | Add auth headers to all JSON-RPC requests (syncServerTime, sendLockScreenCommand, etc.) | Low |

### **NO Changes Needed:**
- ✅ **Audio streaming code**: Already handles authenticated servers via server-provided headers
- ✅ **SlimProto client**: Binary protocol doesn't require authentication
- ✅ **AudioPlayer/CBass**: Receives authenticated stream URLs from server

---

## **Testing Checklist**

### **Basic Functionality:**
- [ ] Test with authentication disabled (current behavior - must still work)
- [ ] Test with authentication enabled (username/password)
- [ ] Test invalid credentials (401 error handling)
- [ ] Test empty username (should behave as no auth)

### **WebView (Material UI):**
- [ ] Material interface loads with valid credentials
- [ ] Material interface shows 401 error with invalid credentials
- [ ] Material interface works without credentials when server auth disabled

### **JSON-RPC:**
- [ ] Server time synchronization works with auth
- [ ] Lock screen play/pause commands work with auth
- [ ] All JSON-RPC calls return 401 with invalid credentials

### **Audio Streaming:**
- [ ] Audio streams play correctly on secured server (should already work)
- [ ] No changes to audio playback behavior

### **Multi-Server:**
- [ ] Different credentials work for primary and backup servers
- [ ] Server switching preserves correct credentials
- [ ] Backup server failover uses correct credentials

### **Connection Testing:**
- [ ] Connection test detects 401 with wrong credentials
- [ ] Connection test succeeds with correct credentials
- [ ] Connection test works without credentials on unsecured servers

---

## **Security Considerations**

### **1. Password Storage:**
- **Current Plan**: UserDefaults (encrypted by iOS automatically)
- **Future Enhancement**: Move to iOS Keychain for production
- **Never**: Log passwords in plaintext or include in error messages

### **2. HTTPS Recommendation:**
- HTTP + Basic Auth sends credentials as **base64-encoded text** (easily decoded)
- Show warning when entering credentials for HTTP servers:
  ```
  ⚠️ Warning: Your server uses HTTP without encryption.
  Credentials are sent as base64-encoded text.
  Consider enabling HTTPS in LMS for better security.
  ```

### **3. Per-Server Credentials:**
- Support different username/password for primary and backup servers
- Each server may have different authentication requirements
- Active server determines which credentials to use

### **4. Credential Validation:**
- Test connection button validates credentials before saving
- Empty username = no authentication (backward compatible)
- Provide clear error messages for authentication failures

---

## **Key Insights from Source Code Analysis**

### **Critical Discovery:**
After analyzing both squeezelite and LMS server source code, we discovered that:

1. **Squeezelite has NO authentication code**
   - The player receives complete HTTP headers from the server via SlimProto
   - These headers already include `Authorization: Basic ...` for secured servers
   - The player simply forwards the headers to the audio stream endpoint

2. **This means:**
   - ✅ Audio streaming already works with secured LMS servers
   - ❌ WebView and JSON-RPC need client-side authentication
   - ✅ Significantly simpler implementation than originally planned

### **How It Works:**
```
Secured LMS Server
    ↓
    [SlimProto 'strm' command with HTTP headers including auth]
    ↓
LyrPlay (receives complete headers)
    ↓
    [Forwards headers verbatim to audio stream]
    ↓
Audio plays successfully ✅
```

---

## **Future Enhancements**

1. **Keychain Integration:**
   - Move password storage from UserDefaults to iOS Keychain
   - More secure for production environments

2. **Biometric Authentication:**
   - Touch ID / Face ID to unlock stored credentials
   - Protect access to settings containing passwords

3. **Multiple Server Profiles:**
   - Save credentials for multiple servers
   - Quick switching between server profiles

4. **Credential Import/Export:**
   - Backup/restore server configurations
   - Share configs between devices (encrypted)

---

## **Documentation Updates Needed**

### **README.md:**
Add section on server authentication:
```markdown
### Server Authentication

LyrPlay supports LMS servers with authentication enabled:

1. Open Settings → Server Configuration
2. Enter your LMS username and password
3. Test connection to verify credentials
4. Save and enjoy secure playback

**Note**: Audio streaming works automatically with secured servers.
Only WebView (Material UI) and server commands require credentials.
```

### **GitHub Issues:**
Create template for authentication-related issues with checklist:
- [ ] Server has authentication enabled in LMS Settings → Security
- [ ] Credentials are correctly entered in LyrPlay Settings
- [ ] Connection test passes with credentials
- [ ] Specific error message from the app

---

**Last Updated:** January 2025
**Status:** Ready for implementation
**Estimated Effort:** 4-6 hours of development + 2-3 hours of testing
