# How to run bisect with git

1. Disable v1 cgroups
   https://wiki.archlinux.org/index.php/cgroups#Disabling_v1_cgroups

2. Configure a slice to cap memory usage: `$ systemctl edit --user --full memlimit.slice --force`
   Type the following and save:

   ```ini
   [Slice]
   MemoryMax=4G
   ```

3. Adjust paths in `bisect.sh` and `testleak.sh` as needed

4. `$ git bisect start bad good`

5. `$ git bisect run ./bisect.sh`
