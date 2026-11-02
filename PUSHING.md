# Pushing to GitHub

Everything is pushed as the repository owner's own GitHub profile (`aliarain`) and nothing
else: no co-author trailers, no tool attribution in commit messages or PR descriptions.

- Remote: `git@github.com:aliarain/nits.git`, branch `main`.
- Identity: `Ali Arain <40721466+aliarain@users.noreply.github.com>` (from the global git config).
- Commits are SSH-signed with a Secretive (Secure Enclave) key, so Touch ID is required.

## Steps

```sh
# git signing reads SSH_AUTH_SOCK, so point it at Secretive first
export SSH_AUTH_SOCK="$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"

git add -A
git commit -m "Short summary of the change"
git push origin main
```

If `git commit` says `No private key found for public key ...github-macbook.pub`, the
`export` line above was skipped. Do not turn signing off.
