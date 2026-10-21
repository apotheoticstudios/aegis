# ADR-0028: Project: Aegis naming

Status: accepted (owner request, 2026-10-21).

The software is **Project: Aegis**. The assistant is **your Aegis**, with a personal name chosen in Personality settings; its default name is Aegis.

Source modules, executables, bundle identifiers and build paths use Aegis (`AegisKit`, `AegisCore`, `Aegis.app`, `dev.aegis.*`). Public Swift symbols previously named Jarvis are renamed consistently; downstream imports must use AegisKit and AegisStorage. The default keyword is Hey Aegis, encoded with the existing pinned model. Custom names remain supported.

Third-party OpenJarvis names, licence attribution, compatibility metadata and existing GitHub links remain unchanged. The source rename does not move the checkout, rename the remote repository, install an app, or migrate existing local settings, memories, databases or model downloads. A replacement installation runs `scripts/migrate-from-jarvis.sh` once (moves the application-support folder, copies preferences, stops the old agents and removes the old app, reading no contents), and macOS asks for permissions again for the new bundle identifiers. The Keychain service names `dev.jarvis.world` and `dev.jarvis.cloud` stay, so saved keys keep working.
