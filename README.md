# Keys

Public GPG key:
- public.asc

Requirements:
- git, curl, gnupg, ssh
- gpg-backup.tar.gz.gpg (installs the keys) OR Yubikey plugged and readable. (Might need pcsd and more on Linux)  

Bootstrap:
```bash
curl -fsSLO https://raw.githubusercontent.com/To999999999/keys/main/setup.sh && chmod +x setup.sh && ./setup.sh; status=$?; rm -f setup.sh; exit $status
```
On debian might need to run this first (for dependencies etc):
```
curl -fsSLO https://raw.githubusercontent.com/To999999999/keys/main/debian_yubikey_setup.sh && chmod +x debian_yubikey_setup.sh && ./debian_yubikey_setup.sh
```
