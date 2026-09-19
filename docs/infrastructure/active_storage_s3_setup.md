# Active Storage and S3

Uploaded files — proofs, disability certifications, vendor W-9s — are Active Storage attachments.

Tests and development default to disk storage. Development can opt into S3; other environments use S3.

One S3 configuration serves both a Bucketeer add-on and direct AWS credentials.

## Which service is used

[`config/initializers/storage.rb`](../../config/initializers/storage.rb) decides in a `to_prepare` block, which runs after the environment files and therefore wins over the `config.active_storage.service` lines in them:

| Environment | Service | Where files go |
| --- | --- | --- |
| test | `:test` | `tmp/storage` |
| development | `:local`, or `:s3` when `USE_S3=true` | `storage/`, or the bucket when `USE_S3=true` |
| everything else | `:s3` | the bucket |

## Credentials

The `s3` entry in [`config/storage.yml`](../../config/storage.yml) reads direct credentials first and falls back to Bucketeer's, so the same deployment works either way and switching providers is an environment-variable change rather than a code change:

| Setting | Direct | Bucketeer fallback | Default |
| --- | --- | --- | --- |
| Access key | `S3_ACCESS_KEY_ID` | `BUCKETEER_AWS_ACCESS_KEY_ID` | — |
| Secret | `S3_SECRET_ACCESS_KEY` | `BUCKETEER_AWS_SECRET_ACCESS_KEY` | — |
| Region | `S3_REGION` | `BUCKETEER_AWS_REGION` | `us-east-1` |
| Bucket | `S3_BUCKET` | `BUCKETEER_BUCKET_NAME` | — |

On Heroku, `heroku addons:create bucketeer:hobbyist` sets its four variables itself and needs nothing further. Anywhere else, set the `S3_*` four.

`storage.yml` also carries commented templates for GCS, Azure, and a mirror service; using one means adding its case to the initializer as well.

## Local development against S3

`.env` is not loaded. `.env.example` exists, but there is no `dotenv-rails` in the Gemfile — the `dotenv` in `Gemfile.lock` arrives only as a Kamal dependency — and [`bin/dev`](../../bin/dev) starts foreman with `--env /dev/null`, which disables foreman's own `.env` handling. Export the variables or put them on the command line:

```bash
USE_S3=true S3_BUCKET=… S3_ACCESS_KEY_ID=… S3_SECRET_ACCESS_KEY=… bin/dev
```

`USE_S3=true` with an incomplete set fails at boot inside the AWS SDK rather than in application code. A missing bucket surfaces as `missing required option :name` from `aws-sdk-s3`, usually preceded by a timeout against `169.254.169.254` as the SDK tries for EC2 instance-profile credentials.

## Direct uploads need bucket CORS

Paper intake, portal proof submission, and vendor W-9 upload all use Active Storage direct upload: the browser `PUT`s the file to the bucket itself, and only the signed blob ID reaches Rails. The bucket therefore needs a CORS rule allowing `PUT` from the application's origin, which nothing in this repository can set — it is bucket-side configuration. A direct upload that fails only in the browser, with the Rails log showing nothing after the `/rails/active_storage/direct_uploads` call, is the usual sign that the rule is missing or does not cover the origin.

These documents contain personal information, so keep the bucket private. The app serves attachments through [Rails proxy URLs](../../config/initializers/active_storage.rb) with signed blob IDs and no default expiry. S3 service URL expiry does not make those Rails links expire.
