web: bundle exec puma -C config/puma.rb
worker: bin/rails solid_queue:start
release: bin/rails db:migrate
