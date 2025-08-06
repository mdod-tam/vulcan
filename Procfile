web: bundle exec puma -C config/puma.rb
release: bin/rails db:migrate
worker: bin/rails solid_queue:start
