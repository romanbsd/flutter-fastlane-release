# frozen_string_literal: true

module ReleaseNumbers
  PLAY_VERSION_CODE_LIMIT = 2_100_000_000
  PLAY_VERSION_CODE_MESSAGE = 'Google Play version codes must be below 2,100,000,001.'

  module_function

  def validate_play_version_code!(number)
    FastlaneCore::UI.user_error!(PLAY_VERSION_CODE_MESSAGE) if number.to_i > PLAY_VERSION_CODE_LIMIT
  end

  def validate_pubspec_floor!(name, number, pubspec_build)
    return if number.to_i >= pubspec_build.to_i

    FastlaneCore::UI.user_error!("#{name} must not be below the pubspec build number.")
  end

  # One above the highest build already shipped, but never below the pubspec build.
  def next_store_build(pubspec_build, store_latest)
    chosen = [pubspec_build, store_latest].max
    chosen <= store_latest ? chosen + 1 : chosen
  end
end
