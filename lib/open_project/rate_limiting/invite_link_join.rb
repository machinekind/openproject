# frozen_string_literal: true

module OpenProject
  module RateLimiting
    # Throttles /account/join/:token, which looks a token up on every hit.
    # Kept in its own bucket so it does not share the registration budget.
    class InviteLinkJoin < Base
      def default_limit
        20
      end

      def default_period
        10.minutes.to_i
      end

      def response_body(retry_after:, **)
        "Too many invite link requests. Try again at #{retry_after.seconds.from_now}.\n"
      end

      protected

      def discriminator(req)
        return unless recognized_route?(req, controller: "account", action: "join")

        client_ip(req)
      end

      def client_ip(req)
        req.env["HTTP_X_REAL_IP"].presence || req.ip
      end
    end
  end
end
