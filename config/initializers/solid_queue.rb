# frozen_string_literal: true

# SolidQueue configuration for Heroku
# No custom configuration needed - using DATABASE_URL

# Connection Pool Guidelines:
# Each worker thread uses 1 connection + 2 for polling/heartbeat
# Total connections needed = (threads + 2) * processes
# With current config: (2 + 2) * 1 = 4 connections minimum per worker
# Ensure your database connection pool size is set accordingly
