# Keys

Public GPG key:
- public.asc

Need to either have gpg-backup.tar.gz.gpg (to install the keys) or the Yubikey plugged (to use the subkeys), and they run the bootstrap.

Bootstrap:
```bash
curl -fsSLO https://raw.githubusercontent.com/To999999999/keys/main/setup.sh && chmod +x setup.sh && ./setup.sh
```
On debian might need to run this first (for dependencies etc):
```
curl -fsSLO https://raw.githubusercontent.com/To999999999/keys/main/debian_yubikey_setup.sh && ./debian_yubikey_setup.sh
```
