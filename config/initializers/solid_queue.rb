# frozen_string_literal: true

# SolidQueue configuration for Heroku
# No custom configuration needed - using DATABASE_URL

# Connection pool sizing: each worker thread uses one connection, plus two for polling and heartbeat.
# A process needs (threads + 2) connections, so size the queue database pool to match.
