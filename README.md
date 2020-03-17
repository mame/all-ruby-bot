# all-ruby bot for Slack

A chat bot to run Ruby publicly

![all-ruby demo](all-ruby-demo.png)

## Minimal Deployment

* Setup Slack App (1)
  * Go to https://api.slack.com/apps and Create New App
  * Memo "Signing Secret"
  * Setup "OAuth & Permissions"
    * Add Scopes: `app_mentions:read`, `chat:write`, and `reactions:write`
    * Memo "Bot User OAuth Access Token" (starting with `xoxb-`)
* Setup the sinatra app anywhere
  * with an environment varibale `ALL_RUBY_BOT_SLACK_API_TOKEN` set as "Bot User OAuth Access Token"
  * with an environment varibale `ALL_RUBY_BOT_SLACK_APP_SECRET_KEY` set as "Signing Secret"
* Setup Slack App (2)
  * Setup "Event Subscriptions"
    * Add "Request URL"
    * Subscribe to `app_mention` bot events
  * "Install App"
