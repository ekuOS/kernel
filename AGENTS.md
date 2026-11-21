# Development policy

- Make frequent, small, coherent commits. Sign every commit (`git commit -S`); do not bypass signing.
- Write all project scripts in Dart, not Bash, other shells, or other scripting languages. Invoke external commands from Dart with explicit argument lists. Keep required Portage phase definitions in their native ebuild format and limit CI shell steps to direct command invocations.
- After validating changes, push the signed commits and monitor the GitHub Actions run for the pushed commit until it completes. Report the run link and result, including the Pages deployment result when applicable.
