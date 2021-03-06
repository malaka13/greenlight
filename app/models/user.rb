# frozen_string_literal: true

# BigBlueButton open source conferencing system - http://www.bigbluebutton.org/.
#
# Copyright (c) 2018 BigBlueButton Inc. and by respective authors (see below).
#
# This program is free software; you can redistribute it and/or modify it under the
# terms of the GNU Lesser General Public License as published by the Free Software
# Foundation; either version 3.0 of the License, or (at your option) any later
# version.
#
# BigBlueButton is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
# PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public License along
# with BigBlueButton; if not, see <http://www.gnu.org/licenses/>.

class User < ApplicationRecord
  attr_accessor :reset_token, :activation_token
  after_create :create_home_room_if_verified
  before_save { email.try(:downcase!) }
  before_create :create_activation_digest

  before_destroy :destroy_rooms

  has_many :rooms
  belongs_to :main_room, class_name: 'Room', foreign_key: :room_id, required: false

  validates :name, length: { maximum: 256 }, presence: true
  validates :provider, presence: true
  validates :image, format: { with: /\.(png|jpg)\Z/i }, allow_blank: true
  validates :email, length: { maximum: 256 }, allow_blank: true,
                    uniqueness: { case_sensitive: false, scope: :provider },
                    format: { with: /\A[\w+\-.]+@[a-z\d\-.]+\.[a-z]+\z/i }

  validates :password, length: { minimum: 6 }, confirmation: true, if: :greenlight_account?, on: :create

  # Bypass validation if omniauth
  validates :accepted_terms, acceptance: true,
                             unless: -> { !greenlight_account? || !Rails.configuration.terms }

  # We don't want to require password validations on all accounts.
  has_secure_password(validations: false)

  class << self
    # Generates a user from omniauth.
    def from_omniauth(auth)
      # Provider is the customer name if in loadbalanced config mode
      provider = auth['provider'] == "bn_launcher" ? auth['info']['customer'] : auth['provider']
      find_or_initialize_by(social_uid: auth['uid'], provider: provider).tap do |u|
        u.name = auth_name(auth) unless u.name
        u.username = auth_username(auth) unless u.username
        u.email = auth_email(auth)
        u.image = auth_image(auth)
        u.email_verified = true
        u.save!
      end
    end

    private

    # Provider attributes.
    def auth_name(auth)
      case auth['provider']
      when :microsoft_office365
        auth['info']['display_name']
      else
        auth['info']['name']
      end
    end

    def auth_username(auth)
      case auth['provider']
      when :google
        auth['info']['email'].split('@').first
      when :bn_launcher
        auth['info']['username']
      else
        auth['info']['nickname']
      end
    end

    def auth_email(auth)
      auth['info']['email']
    end

    def auth_image(auth)
      case auth['provider']
      when :twitter
        auth['info']['image'].gsub("http", "https").gsub("_normal", "")
      else
        auth['info']['image'] unless auth['provider'] == :microsoft_office365
      end
    end
  end

  # Activates an account and initialize a users main room
  def activate
    update_attribute(:email_verified, true)
    update_attribute(:activated_at, Time.zone.now)

    initialize_main_room
  end

  def send_activation_email(url)
    UserMailer.verify_email(self, url).deliver
  end

  # Sets the password reset attributes.
  def create_reset_digest
    self.reset_token = User.new_token
    update_attribute(:reset_digest,  User.digest(reset_token))
    update_attribute(:reset_sent_at, Time.zone.now)
  end

  # Sends password reset email.
  def send_password_reset_email(url)
    UserMailer.password_reset(self, url).deliver_now
  end

  # Returns true if the given token matches the digest.
  def authenticated?(attribute, token)
    digest = send("#{attribute}_digest")
    return false if digest.nil?
    BCrypt::Password.new(digest).is_password?(token)
  end

  # Return true if password reset link expires
  def password_reset_expired?
    reset_sent_at < 2.hours.ago
  end

  # Retrives a list of all a users rooms that are not the main room, sorted by last session date.
  def secondary_rooms
    secondary = (rooms - [main_room])
    no_session, session = secondary.partition { |r| r.last_session.nil? }
    sorted = session.sort_by(&:last_session)
    sorted + no_session
  end

  def name_chunk
    charset = ("a".."z").to_a - %w(b i l o s) + ("2".."9").to_a - %w(5 8)
    chunk = name.parameterize[0...3]
    if chunk.empty?
      chunk + (0...3).map { charset.to_a[rand(charset.size)] }.join
    elsif chunk.length == 1
      chunk + (0...2).map { charset.to_a[rand(charset.size)] }.join
    elsif chunk.length == 2
      chunk + (0...1).map { charset.to_a[rand(charset.size)] }.join
    else
      chunk
    end
  end

  def greenlight_account?
    provider == "greenlight"
  end

  def self.digest(string)
    cost = ActiveModel::SecurePassword.min_cost ? BCrypt::Engine::MIN_COST : BCrypt::Engine.cost
    BCrypt::Password.create(string, cost: cost)
  end

  # Returns a random token.
  def self.new_token
    SecureRandom.urlsafe_base64
  end

  private

  def create_activation_digest
    # Create the token and digest.
    self.activation_token  = User.new_token
    self.activation_digest = User.digest(activation_token)
  end

  # Destory a users rooms when they are removed.
  def destroy_rooms
    rooms.destroy_all
  end

  # Assigns the user a BigBlueButton id and a home room if verified
  def create_home_room_if_verified
    self.uid = "gl-#{(0...12).map { (65 + rand(26)).chr }.join.downcase}"

    initialize_main_room if email_verified
    save
  end

  # Initializes a room for the user and assign a BigBlueButton user id.
  def initialize_main_room
    self.main_room = Room.create!(owner: self, name: I18n.t("home_room"))
    save
  end
end
