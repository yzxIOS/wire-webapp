#
# Wire
# Copyright (C) 2016 Wire Swiss GmbH
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see http://www.gnu.org/licenses/.
#

window.z ?= {}
z.service ?= {}

CLIENT_CONFIG =
  CONNECTIVITY_CHECK:
    INITIAL_TIMEOUT: 0
    RECHECK_TIMEOUT: 2000
    REQUEST_TIMEOUT: 500
  IGNORED_BACKEND_ERRORS: [
    z.service.BackendClientError::STATUS_CODE.BAD_GATEWAY
    z.service.BackendClientError::STATUS_CODE.BAD_REQUEST
    z.service.BackendClientError::STATUS_CODE.CONFLICT
    z.service.BackendClientError::STATUS_CODE.CONNECTIVITY_PROBLEM
    z.service.BackendClientError::STATUS_CODE.INTERNAL_SERVER_ERROR
    z.service.BackendClientError::STATUS_CODE.NOT_FOUND
    z.service.BackendClientError::STATUS_CODE.PRECONDITION_FAILED
    z.service.BackendClientError::STATUS_CODE.REQUEST_TIMEOUT
    z.service.BackendClientError::STATUS_CODE.REQUEST_TOO_LARGE
    z.service.BackendClientError::STATUS_CODE.TOO_MANY_REQUESTS
  ]
  IGNORED_BACKEND_LABELS: [
    z.service.BackendClientError::LABEL.PASSWORD_EXISTS
    z.service.BackendClientError::LABEL.TOO_MANY_CLIENTS
    z.service.BackendClientError::LABEL.TOO_MANY_MEMBERS
  ]


# Client for all backend REST API calls.
class z.service.Client
  @::CONNECTIVITY_CHECK_TRIGGER =
    ACCESS_TOKEN_REFRESH: 'z.service.Client::CONNECTIVITY_CHECK_TRIGGER.ACCESS_TOKEN_REFRESH'
    ACCESS_TOKEN_RETRIEVAL: 'z.service.Client::CONNECTIVITY_CHECK_TRIGGER.ACCESS_TOKEN_RETRIEVAL'
    APP_INIT_RELOAD: 'z.service.Client.CONNECTIVITY_CHECK_TRIGGER.APP_INIT_RELOAD'
    CONNECTION_REGAINED: 'z.service.Client.CONNECTIVITY_CHECK_TRIGGER.CONNECTION_REGAINED'
    LOGIN_REDIRECT: 'z.service.Client.CONNECTIVITY_CHECK_TRIGGER.LOGIN_REDIRECT'
    REQUEST_FAILURE: 'z.service.Client.CONNECTIVITY_CHECK_TRIGGER.REQUEST_FAILURE'
    UNKNOWN: 'z.service.Client.CONNECTIVITY_CHECK_TRIGGER.UNKNOWN'


  ###
  Construct a new client.

  @param settings [Object] Settings for different backend environments
  @option settings [String] environment
  @option settings [String] rest_url
  @option settings [String] web_socket_url
  @option settings [String] parameter
  ###
  constructor: (settings) ->
    @logger = new z.util.Logger 'z.service.Client', z.config.LOGGER.OPTIONS

    z.util.Environment.backend.current = settings.environment
    @rest_url = settings.rest_url
    @web_socket_url = settings.web_socket_url

    @connectivity_queue = new z.util.PromiseQueue()

    @request_queue = []
    @request_queue_blocked_state = ko.observable z.service.RequestQueueBlockedState.NONE

    @access_token = ''
    @access_token_type = ''

    @number_of_requests = ko.observable 0
    @number_of_requests.subscribe (new_value) ->
      amplify.publish z.event.WebApp.TELEMETRY.BACKEND_REQUESTS, new_value

    # http://stackoverflow.com/a/18996758/451634
    pre_filters = $.Callbacks()
    pre_filters.before_each_request = (options, originalOptions, jqXHR) =>
      jqXHR.wire =
        original_request_options: originalOptions
        request_id: @number_of_requests()
        requested: new Date()

    $.ajaxPrefilter pre_filters.before_each_request

  ###
  Create a request URL.
  @param url [String] API endpoint to be prefixed with REST API environment
  @return [String] REST API endpoint
  ###
  create_url: (url) ->
    return "#{@rest_url}#{url}"

  ###
  Request backend status.
  @return [$.Promise] jquery AJAX promise
  ###
  status: =>
    $.ajax
      type: 'HEAD'
      timeout: CLIENT_CONFIG.CONNECTIVITY_CHECK.REQUEST_TIMEOUT
      url: @create_url '/self'

  ###
  Delay a function call until backend connectivity is guaranteed.
  @param [z.service.Client::CONNECTIVITY_CHECK_TRIGGER] source - Trigger that requested connectivity check
  @return [Promise] Promise that resolves once the connectivity is verified
  ###
  execute_on_connectivity: (source) =>
    source = z.service.Client::CONNECTIVITY_CHECK_TRIGGER.UNKNOWN if not source
    @logger.info "Connectivity check requested by '#{source}'"

    _check_status = =>
      @status()
      .done (jqXHR) =>
        @logger.info 'Connectivity verified', jqXHR
        @connectivity_timeout = undefined
        @connectivity_queue.pause false
      .fail (jqXHR) =>
        if jqXHR.readyState is 4
          @logger.info "Connectivity verified by server error '#{jqXHR.status}'", jqXHR
          @connectivity_queue.pause false
          @connectivity_timeout = undefined
        else
          @logger.warn 'Connectivity could not be verified... retrying'
          @connectivity_queue.pause true
          @connectivity_timeout = window.setTimeout _check_status, CLIENT_CONFIG.CONNECTIVITY_CHECK.RECHECK_TIMEOUT

    @connectivity_queue.pause true
    queued_promise = @connectivity_queue.push -> Promise.resolve()
    if not @connectivity_timeout
      @connectivity_timeout = window.setTimeout _check_status, CLIENT_CONFIG.CONNECTIVITY_CHECK.INITIAL_TIMEOUT

    return queued_promise

  # Execute queued requests.
  execute_request_queue: =>
    return if not @access_token or not @request_queue.length

    @logger.info "Executing '#{@request_queue.length}' queued requests"
    for request in @request_queue
      [config, resolve_fn, reject_fn] = request
      @logger.info "Queued '#{config.type}' request to '#{config.url}' executed"
      @send_request config
      .then resolve_fn
      .catch (error) =>
        @logger.info "Failed to execute queued '#{config.type}' request to '#{config.url}'", error
        reject_fn error

    @request_queue.length = 0

  ###
  Send jQuery AJAX request.
  @see http://api.jquery.com/jquery.ajax/#jQuery-ajax-settings
  @param config [Object]
  @option config [String] contentType
  @option config [Object] data
  @option config [Object] headers
  @option config [Boolean] processData
  @option config [Number] timeout
  @option config [String] type
  @option config [String] url
  @option config [Boolean] withCredentials
  ###
  send_request: (config) ->
    return new Promise (resolve, reject) =>
      if @request_queue_blocked_state() isnt z.service.RequestQueueBlockedState.NONE
        return @_push_to_request_queue [config, resolve, reject], @request_queue_blocked_state()

      if @access_token
        config.headers = $.extend config.headers or {}, Authorization: "#{@access_token_type} #{@access_token}"

      if config.withCredentials
        config.xhrFields = withCredentials: true

      @number_of_requests @number_of_requests() + 1

      $.ajax
        cache: config.cache
        contentType: config.contentType
        data: config.data
        headers: config.headers
        processData: config.processData
        timeout: config.timeout
        type: config.type
        url: config.url
        xhrFields: config.xhrFields
      .done (data, textStatus, jqXHR) =>
        resolve data
        @logger.debug @logger.levels.OFF, "Server Response '#{jqXHR.wire?.request_id}' from '#{config.url}':", data
      .fail (jqXHR, textStatus, errorThrown) =>
        switch jqXHR.status
          when z.service.BackendClientError::STATUS_CODE.CONNECTIVITY_PROBLEM
            @request_queue_blocked_state z.service.RequestQueueBlockedState.CONNECTIVITY_PROBLEM
            @_push_to_request_queue [config, resolve, reject], @request_queue_blocked_state()
            @execute_on_connectivity(z.service.Client::CONNECTIVITY_CHECK_TRIGGER.REQUEST_FAILURE)
            .then =>
              @request_queue_blocked_state z.service.RequestQueueBlockedState.NONE
              @execute_request_queue()
            return
          when z.service.BackendClientError::STATUS_CODE.UNAUTHORIZED
            @_push_to_request_queue [config, resolve, reject], z.service.RequestQueueBlockedState.ACCESS_TOKEN_REFRESH
            amplify.publish z.event.WebApp.CONNECTION.ACCESS_TOKEN.RENEW, 'Unauthorized backend request'
            return
          when z.service.BackendClientError::STATUS_CODE.FORBIDDEN
            if jqXHR.responseJSON?.label in CLIENT_CONFIG.IGNORED_BACKEND_LABELS
              @logger.warn "Server request failed: #{jqXHR.responseJSON?.label}"
            else
              Raygun.send new Error "Server request failed: #{jqXHR.responseJSON?.label}"
          else
            if jqXHR.status not in CLIENT_CONFIG.IGNORED_BACKEND_ERRORS
              Raygun.send new Error "Server request failed: #{jqXHR.status}"

        reject jqXHR.responseJSON or new z.service.BackendClientError jqXHR.status

  ###
  Send AJAX request with compressed JSON body.

  @note ContentType will be overwritten with 'application/json; charset=utf-8'
  @see send_request for valid parameters
  ###
  send_json: (config) ->
    json_config =
      contentType: 'application/json; charset=utf-8'
      data: pako.gzip JSON.stringify config.data if config.data
      headers:
        'Content-Encoding': 'gzip'
      processData: false
    @send_request $.extend config, json_config, true

  _push_to_request_queue: ([config, resolve_fn, reject_fn], reason) ->
    @logger.info "Adding '#{config.type}' request to '#{config.url}' to queue due to '#{reason}'", config
    @request_queue.push [config, resolve_fn, reject_fn]
