# Fortyfives.net
A website for the card game 45s. <https://fortyfives.net>

## Deploying
Cakewalk:

`docker pull thwar/fortyfives.net:latest`

`docker-compose up`

Use the `docker-compose-env.yml` if you want to use a `.env` file. 
(see [example-env.env](example-env.env) for more details)

Generate secrets with `mix phx.gen.secret`.

Please see [structure.md](structure.md) to see the website's structure

# Resources Used
https://github.com/SportsDAO/playing-card/tree/master
He doesn't have a license on his cards

https://github.com/vcjhwebdev/blackjack
This is the red back of the cards. It also has no license.
