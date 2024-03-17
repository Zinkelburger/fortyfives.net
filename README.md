# Fortyfives.net
A website for the card game 45s. <https://fortyfives.net>

## Deploying
Cakewalk:

`docker pull thwar/fortyfives.net:latest`

`docker-compose up`

Use the `docker-compose-env.yml` if you want to use a `.env` file. 

Generate secrets with `mix phx.gen.secret`.

## Structure:

## Website Structure

### Landing Page
- **Home:** `/`

### Authentication
- **Register:** `/users/register`
- **Login:** `/users/log_in`
- **Forgot Password:** `/users/reset_password`
- **Reset Password:**  `/users/reset_password/:token`
- **Confirm Email:** `/users/confirm/:token`

### User Settings
- **Settings:** `/users/settings`
- **Confirm Email Change:** `/users/settings/confirm_email/:token`

### Gameplay
- **Play (Authenticated):** Join the game queue at `/play`.
- **Play (Anonymous):** Unauthenticated users, `/play_anonymous`
- **Game:** Users can access a specific game using its ID at `/game/:id`. This is a live view for the game interface.

### User Management
- **Log Out:** `/users/log_out`.
- **Confirm Registration:** `/users/confirm/:token`
- **Resend Confirmation Instructions:** `/users/confirm`

# Resources Used
https://github.com/SportsDAO/playing-card/tree/master
He doesn't have a license on his cards

https://github.com/vcjhwebdev/blackjack
This is the red back of the cards. It also has no license.
