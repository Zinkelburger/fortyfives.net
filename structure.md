
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