FROM docker.io/hexpm/elixir:1.19.6-erlang-27.3.4.19-alpine-3.24.3@sha256:97f49c06689cae6411d430fa7658e2a7c8fb6b87951e85533c1a98dc85b6d043

# Install build dependencies
RUN apk update && \
    apk upgrade --no-cache && \
    apk add --no-cache \
      build-base \
      git \
      bash \
      inotify-tools \
      sqlite

RUN addgroup -S app && adduser -S -G app -h /home/app app

# Set the working directory inside the container
WORKDIR /app
RUN chown app:app /app
USER app

# Install hex, rebar, and the Phoenix framework itself
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy over all the necessary application files and directories
COPY --chown=app:app config/ config/
COPY --chown=app:app lib/ lib/
COPY --chown=app:app priv/ priv/
COPY --chown=app:app assets/ assets/
COPY --chown=app:app mix.exs .
COPY --chown=app:app mix.lock .

# Fetch the application dependencies and compile the app
RUN mix do deps.get, deps.compile, compile

# Digest the static assets
RUN mix phx.digest

# Copy the entrypoint script to the container
COPY --chown=app:app entrypoint.sh /app/entrypoint.sh

# Make the script executable
RUN chmod +x /app/entrypoint.sh

# Expose port 4000 for the app
EXPOSE 4000

# Use the entrypoint script to run migrations and then start the Phoenix server
ENTRYPOINT ["/app/entrypoint.sh"]
