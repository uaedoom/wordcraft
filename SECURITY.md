# Security Policy

WordCraft opens untrusted files (`.docx`, RTF, HTML, text), so parser bugs matter.

If you find a vulnerability (for example a crash or memory problem triggered by a crafted `.docx`), please **report it privately** using GitHub's "Report a vulnerability" button on the Security tab rather than opening a public issue. Include a sample file if you can.

The app runs inside the macOS App Sandbox with no network access and only reads or writes files you choose.
