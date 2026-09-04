# Fortyfives.net
A website for the card game 45s. <https://fortyfives.net>

## Deploying

1. Copy `example-env.env` to `.env` and replace every `CHANGE_ME` value.
2. Generate `SECRET_KEY_BASE` with `mix phx.gen.secret`.
3. Set `APP_IMAGE` to the immutable digest printed by the release build.
4. Start the TLS-terminating stack:

   `docker compose -f docker-compose-nginx.yml up -d`

Do not commit `.env`. Rotate any database password or `SECRET_KEY_BASE` that
has ever appeared in Git history before deploying these changes. After
rotation, coordinate a history rewrite (for example with `git filter-repo`) and
invalidate old clones if the repository has been shared. The database is
intentionally not published on a host port.

For local app-only access, `docker-compose.yml` binds the Phoenix port to
`127.0.0.1`; place a TLS reverse proxy in front before exposing it publicly.

Please see [structure.md](structure.md) to see the website's structure

# Resources Used
https://github.com/SportsDAO/playing-card/tree/master
He doesn't have a license on his cards

https://github.com/vcjhwebdev/blackjack
This is the red back of the cards. It also has no license.
