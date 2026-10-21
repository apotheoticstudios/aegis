# ADR-0022: Natural interruption during an open voice conversation

Status: implemented for owner testing, 2026-10-19. Issue #253.

The owner wants to take the turn while Aegis is speaking without repeating a wake phrase. Waiting for a complete transcript would make Stop feel slow; treating any noise or acknowledgement as an interruption would continually cut off replies.

During opted-in hands-free listening, an open panel and active reply permit temporary on-device speech recognition from Apple's voice-processed, echo-cancelled microphone input. Idle audio remains keyword-only. Partial results are checked for direct questions, corrections and turn-taking requests (for example "Wait", "No, I meant…", "What about…"). A match stops local/system playback and promotes the same recognition session to the owner's next question, keeping its opening words. There is no extra spoken acknowledgement. The accepted final utterance follows the existing read-only question/action-safety paths.

This is conservative conversational cue detection, not speaker identification or mind-reading. Background statements and short acknowledgements do not take the turn; residual phrases contained in the current spoken answer are rejected. Another nearby speaker asking a direct question may still be mistaken for the owner. Echo cancellation also depends on the audio device and room. If voice processing is unavailable, playback-time recognition stays disabled; existing wake/question listening remains available.

Unaccepted partial text and audio stay in bounded working memory, are discarded, and never reach conversation history, model prompts, logs or storage. Panel closure, recognizer cancellation and natural playback completion invalidate unaccepted work so it cannot become a question later. No audio is sent to a server, no speaker enrollment is collected, and no new dependency or wire contract is introduced.

Apple's AVAudioIONode API describes voice processing as removing audio played by the device from microphone input: [setVoiceProcessingEnabled](https://developer.apple.com/documentation/avfaudio/avaudioionode/setvoiceprocessingenabled(_:)). Device/room overlap behavior needs owner verification; automated tests use invented text/audio and do not open a real microphone.
