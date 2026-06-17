// Re-export the sherpa-onnx C API (the `sherpa_onnx` Clang module defined by the vendored
// xcframework's module map) so app code can `import SherpaOnnxWrapper` and call the C TTS API
// directly. This target also carries the link settings the static libs require (see Package.swift).
@_exported import sherpa_onnx
