import EarsCore

/// Disambiguation alias for ``EarsCore/AudioBuffer``.
///
/// `AudioBuffer` collides with CoreAudio's C struct of the same name in any file
/// that imports AVFoundation, and the module can't be named explicitly because
/// `EarsCore` is also a type. This file imports only `EarsCore`, so the name
/// resolves unambiguously to the model type; other files use this alias.
public typealias CapturedAudioBuffer = AudioBuffer
