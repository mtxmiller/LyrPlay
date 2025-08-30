# Slimserver Pull Request Plan: Capabilities-Driven Transcoding

**Goal**: Make LMS server automatically generate optimal transcoding rules based on client capabilities, eliminating the need for manual convert.conf configuration for modern clients.

## Current Problem Analysis

### How It Works Now
1. **Client sends capabilities**: `Model=LyrPlay,ModelName=LyrPlay,Firmware=v1.6-CBass,Codecs=flac,ops,aac,mp3`
2. **Server parses supported formats**: `$client->formats()` returns `['flac', 'ops', 'aac', 'mp3']`  
3. **Server builds profile list**: Uses `@supportedformats` from `CapabilitiesHelper::supportedFormats()`
4. **Server matches against convert.conf**: Looks for rules like `flc ops * *` 
5. **Problem**: No default rules exist for modern formats like Opus

### The Core Issue
The server **correctly parses** client capabilities and **knows** the client supports Opus, but **fails** because:
- Default convert.conf lacks comprehensive rules for modern formats
- No automatic rule generation exists
- Manual configuration required for every new format/client combination

## Pull Request Strategy: Two-Phase Approach

### Phase 1: Enhanced Default Rules (Low-Risk, High Impact)

**Goal**: Add comprehensive default transcoding rules to convert.conf for modern formats.

**Files to Modify**:
- `/slimserver/convert.conf`

**Changes**:
```bash
# Add at the end of convert.conf (before wildcard rules)

# Modern codec support - Opus
flc ops * *
	# IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t ogg -C 8 -

# Modern codec support - AAC High Quality  
flc aac * *
	# IFB:{BITRATE=-b %B}T:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [fdkaac] -m 5 -p 2 $BITRATE$ $RESAMPLE$ -f 2 -o - -

# iOS-Compatible FLAC (ensures proper headers for seeking)
flc flc ios *
	# IFT:{START=--skip=%t}U:{END=--until=%v}D:{RESAMPLE=-r %d}
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -C 0 -b 16 -

# Add other missing format combinations...
```

**Benefits**:
- ✅ Works immediately for all existing and future clients
- ✅ No code changes required  
- ✅ Zero risk of breaking existing functionality
- ✅ LyrPlay works out-of-the-box after server update

### Phase 2: Smart Rule Generation (Advanced Enhancement)

**Goal**: Automatically generate optimal transcoding rules based on client capabilities and priorities.

**Files to Modify**:
- `/Slim/Player/TranscodingHelper.pm` (main logic)
- `/Slim/Player/CapabilitiesHelper.pm` (capability parsing enhancements)
- `/convert.conf` (add capability-driven rule templates)

#### Key Changes Required:

**1. Enhanced Profile Generation** (`TranscodingHelper.pm:368-386`)
```perl
# Current code builds profiles from static @supportedformats
foreach my $checkFormat (@supportedformats) {
    push @profiles, "$type-$checkFormat-*-*";
}

# Enhanced code: Add capability-driven profiles BEFORE static rules
my @capabilityProfiles = _generateCapabilityProfiles($client, $type, \@supportedformats);
unshift @profiles, @capabilityProfiles;  # Higher priority than static rules
```

**2. New Function: `_generateCapabilityProfiles()`**
```perl
sub _generateCapabilityProfiles {
    my ($client, $inputType, $supportedformats) = @_;
    my @profiles = ();
    
    return @profiles unless $client;
    
    # Get client capabilities
    my $modelName = $client->getCapability('ModelName') || '';
    my $codecs = $client->getCapability('Codecs') || '';
    my @clientCodecs = split /,/, $codecs;
    
    # Priority order for format selection (most efficient first)
    my %formatPriority = (
        'ops' => 1,  # Opus - best compression
        'aac' => 2,  # AAC - good compression  
        'flc' => 3,  # FLAC - lossless
        'mp3' => 4,  # MP3 - compatibility
    );
    
    # Sort supported formats by priority
    my @orderedFormats = sort { 
        ($formatPriority{$a} || 99) <=> ($formatPriority{$b} || 99) 
    } grep { exists $formatPriority{$_} } @$supportedformats;
    
    my $clientid = $client->id();
    my $model = $client->model();
    
    foreach my $format (@orderedFormats) {
        # Generate profiles with capability-aware naming
        if ($modelName) {
            push @profiles, "$inputType-$format-$model-ModelName:$modelName";
            push @profiles, "$inputType-$format-*-ModelName:$modelName";  
        }
        
        # Standard profiles (existing behavior)
        push @profiles, (
            "$inputType-$format-$model-$clientid",
            "$inputType-$format-*-$clientid",
            "$inputType-$format-$model-*"
        );
    }
    
    return @profiles;
}
```

**3. Enhanced Convert.conf Templates**
```bash
# Capability-driven rule templates (matched by _generateCapabilityProfiles)

# ModelName-based rules for modern iOS clients
flc ops * ModelName:LyrPlay
	# High-quality Opus for mobile bandwidth efficiency
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b 16 -r 44100 -c 2 -L - -t ogg -C 8 -

flc flc * ModelName:LyrPlay  
	# iOS-compatible FLAC with proper headers
	[flac] -dcs $START$ $END$ --force-raw-format --sign=signed --endian=little -- $FILE$ | [sox] -q -t raw --encoding signed-integer -b $SAMPLESIZE$ -r $SAMPLERATE$ -c $CHANNELS$ -L - -t flac -C 0 -b 16 -

# ModelName rules for other modern clients
flc ops * ModelName:squeezelite
	[flac] -dcs $START$ $END$ -- $FILE$ | [sox] -t wav - -t ogg -C 6 -

# Fallback to enhanced defaults
flc ops * *
	[flac] -dcs $START$ $END$ -- $FILE$ | [sox] -t wav - -t ogg -C 8 -
```

## Implementation Approach

### Recommended Phased Implementation

**Phase 1 First** (Immediate Impact):
- Submit PR with enhanced default convert.conf rules
- Focuses on adding missing format combinations 
- Zero code changes, maximum compatibility
- Solves 90% of current issues including LyrPlay

**Phase 2 Later** (Advanced Features):
- Submit separate PR with smart rule generation
- Requires more extensive testing
- Enables future extensibility and optimization
- Builds on proven Phase 1 foundation

### Testing Strategy

**Phase 1 Testing**:
- Test all new convert.conf rules with multiple client types
- Verify existing functionality unchanged
- Test format priority and fallback behavior

**Phase 2 Testing**:  
- Test capability parsing and profile generation
- Verify ModelName-based rule matching
- Test priority ordering (capability rules > static rules)
- Ensure backward compatibility with existing convert.conf

## Benefits of This Approach

### For LyrPlay Users:
- ✅ **Zero configuration required** - works out of the box
- ✅ **Optimal format selection** - Opus for bandwidth, FLAC with proper headers
- ✅ **Universal compatibility** - works on all iOS devices automatically

### For LMS Server:
- ✅ **Backward compatible** - existing functionality unchanged
- ✅ **Future-proof** - supports new clients automatically  
- ✅ **Maintainable** - reduces need for custom user configurations
- ✅ **Smart defaults** - server makes optimal decisions based on client capabilities

### For All Modern Clients:
- ✅ **Reduced configuration burden** - fewer manual convert.conf rules needed
- ✅ **Better user experience** - works immediately after client installation
- ✅ **Optimal performance** - server selects best format for each client automatically

## Pull Request Structure

### Phase 1 PR: "Add comprehensive default transcoding rules for modern formats"
- **Files**: `convert.conf` only
- **Risk**: Minimal (additive changes only)
- **Impact**: High (solves most user configuration issues)

### Phase 2 PR: "Add capability-driven smart transcoding rule generation" 
- **Files**: `TranscodingHelper.pm`, `CapabilitiesHelper.pm`, `convert.conf`
- **Risk**: Medium (requires extensive testing)
- **Impact**: Very High (transforms server into smart audio optimizer)

## Implementation Timeline

1. **Phase 1 Development**: 1-2 weeks
   - Research all missing format combinations
   - Test transcoding commands across platforms
   - Create comprehensive convert.conf additions

2. **Phase 1 Testing**: 2-3 weeks  
   - Test with multiple client types (LyrPlay, squeezelite, hardware)
   - Verify performance and quality across formats
   - Community testing with beta users

3. **Phase 2 Development**: 3-4 weeks
   - Implement capability parsing enhancements
   - Create smart profile generation logic
   - Add ModelName-based rule matching

4. **Phase 2 Testing**: 3-4 weeks
   - Extensive regression testing
   - Performance impact analysis
   - Community beta testing

## Success Metrics

**Phase 1 Success**:
- LyrPlay works without manual convert.conf configuration
- All modern audio formats supported by default
- Zero reported regressions from existing users

**Phase 2 Success**:  
- Server automatically optimizes transcoding based on client capabilities
- Reduced user support requests about transcoding configuration
- New clients work optimally without manual intervention

---

**Next Steps**: Validate approach with slimserver maintainers, then begin Phase 1 development and testing.