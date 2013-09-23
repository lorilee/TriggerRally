define [
  'backbone-full'
  'THREE'
  'util/util'
  'client/car'
  'cs!models/index'
  'cs!views/inspector'
  'cs!views/purchase'
  'cs!views/view'
  'jade!templates/home'
], (
  Backbone
  THREE
  util
  clientCar
  models
  InspectorView
  PurchaseView
  View
  template
) ->
  Vec3 = THREE.Vector3

  class HomeView extends View
    className: 'overlay'
    template: template
    constructor: (@app, @client) -> super()

    initialize: ->
      @listenTo @app.root, 'change:user', => @render()

    viewModel: ->
      # products = @app.root.user?.products ? []
      # purchased: 'packa' in products
      credits: @app.root.user?.credits

    afterRender: ->
      do updateDriveButton = =>
        trackId = @app.root.track?.id
        @$('.drivebutton').attr 'href', "/track/#{trackId}/drive" if trackId
      @listenTo @app.root, 'change:track.', updateDriveButton

      # do updatePromo = =>
      #   products = @app.root.user?.products ? []
      #   @$('.ignition-promo').toggleClass 'hidden', 'ignition' in products
      #   @$('.mayhem-promo').toggleClass 'hidden', 'mayhem' in products

      # @listenTo @app.root, 'change:user.products', updatePromo

      @$('.purchaseplus a').on 'click', (event) =>
        purchaseView = new PurchaseView @app.root.user, @app, @client
        @app.unifiedView.setDialog purchaseView
        purchaseView.render()
        false

      return
