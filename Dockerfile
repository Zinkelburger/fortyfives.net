# Use an official Elixir runtime as a parent image
FROM elixir:1.15

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

RUN apt-get update && apt-get install -y inotify-tools

# Set the working directory inside the container
WORKDIR /app

# Install the Phoenix framework itself
RUN mix archive.install hex phx_new 1.5.9 --force

# Copy over all the necessary application files and directories
COPY config/ config/
COPY lib/ lib/
COPY priv/ priv/
COPY mix.exs .
COPY mix.lock .

# Install PostgreSQL client
RUN apt update && apt install -y postgresql-client

# Fetch the application dependencies and compile the app
RUN mix do deps.get, deps.compile, compile

# Copy the entrypoint script to the container
COPY entrypoint.sh /app/entrypoint.sh

# Make the script executable
RUN chmod +x /app/entrypoint.sh

# Expose port 4000 for the app
EXPOSE 4000

# Use the entrypoint script to run migrations and then start the Phoenix server
ENTRYPOINT ["/app/entrypoint.sh"]
