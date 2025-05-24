Reviewing the state of the Zig OTel SDK compared to the spec and the C++ reference: the [common] directory

## Initial Request
Analyze the current state of the `otel/src/sdk/[common]` directory against our proposed OpenTelemetry Zig module structure, comparing what we have implemented versus what we haven't, and to create a plan without making any code changes.

## Steps to take

### 1. **Architectural Analysis Against Proposed Structure**
Examine our current SDK [common] implementation against the proposed structure in `PROPOSED_STRUCTURE.md`. Note which files are either missing or unexpectedly found.

### 2. **Comparison with C++ Reference Implementation**
Analyze the C++ OpenTelemetry SDK's version of the directory under `otel/refernce/cpp-sdk` directory to validate our approach:
- **Core components match:** do the core components in there match?
- **Additional C++ components identified:** Are there things the cpp version has that the zig version should consider implementing?
- **Zig-specific assessment:** Some C++ components aren't needed due to Zig's different memory model and async patterns, can those be identified?

### 3. **Unnecessary functionality**
Keeping in mind that we are going for a minimal viable product for now, what is being build that is beyond the MVP spec for the current objective. Is there any logic that could be removed to make the code base simplier until we get all the main functionaly built out?

### 4. **Architectural Issue Resolution**
How do those identified components compare against the Otel specification, and with our current model of API and SDK separation?

### 5. **Test Coverage Quality Review**
Analyze the test coverage in the [common] directory and report what you find. Especially report on the quality and accurcy of the tests. Highlight areas that are incomplete. Give an overall assessment. You won't be able to run the tests.

Create a final report that looks similar (feel free to change) to the following:

## Key Findings

### ✅ **What Works Well:**
- SDK [common] structure aligns with both proposed architecture and C++ reference
- Core functionality (time, ID generation, configuration) is implemented correctly
- Test coverage is solid for primary use cases
- Architectural separation between API and SDK layers is sound

### 🔧 **Issues to Resolve:**
- Removed duplicate `key_value.zig` that violated layer separation
- Fixed critical date calculation bug in timestamp formatting
- Validated that SDK [common] can be tested in isolation

### 📋 **Future Considerations:**
- Could add `attribute_utils.zig` for SDK-level attribute processing when needed
- Environment variable testing could be expanded
- Base64 utilities not needed (Zig stdlib provides `std.base64`)

### **Testing Quality**
- tests match their names.
- tests cover the most common areas.
- lacking in Environment or edge case testing, but OK for the MVP state.
