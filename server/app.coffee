# Copyright (c) 2012 jareiko. All rights reserved.

"use strict"

connect = require('connect')
cookie = require('cookie')
express = require('express')
http = require('http')
mongoose = require('mongoose')
mongoskin = require('mongoskin')
session_mongoose = require('session-mongoose')
socketio = require('socket.io')
stylus = require('stylus')
passport = require('passport')
FacebookStrategy = require('passport-facebook').Strategy
GoogleStrategy = require('passport-google').Strategy
TwitterStrategy = require('passport-twitter').Strategy
LocalStrategy = require('passport-local').Strategy

config = require('./config')
routes = require('./routes')
objects = require('./objects')

getIsodate = -> new Date().toISOString()
express.logger.format 'isodate', (req, res) -> getIsodate()
log = (msg) ->
  isodate = getIsodate()
  console.log "[#{isodate}] #{msg}"

mongoose.connection.on "error", (err) ->
  log "Could not connect to mongo server!"
  log err.message

SessionStore = session_mongoose(connect)
sessionStore = new SessionStore(
  url: "mongodb://#{config.MONGODB_HOST}/sessions"
  # Expiration check worker run interval in millisec (default: 60000)
  interval: 120000
)

User = mongoose.model('User')
UserPassport = mongoose.model('UserPassport')
Car = mongoose.model('Car')
Track = mongoose.model('Track')
Run = mongoose.model('Run')

{ handleIPN } = require './ipn'

# Alternate DB connection
# dbUrl = "#{config.db.host}:#{config.db.port}/#{config.db.name}?auto_reconnect"
# db = mongoskin.db dbUrl, { safe: true }


log "Base directory: #{__dirname}"

app = module.exports = express()

PORT = process.env.PORT or 80
DOMAIN = process.env.DOMAIN or 'triggerrally.com'
NODE_ENV = process.env.NODE_ENV
PUBLIC_PORT = if NODE_ENV is 'production' then 80 else PORT
PORT_SUFFIX = if PUBLIC_PORT is 80 then "" else ":#{PUBLIC_PORT}"
URL_PREFIX = "http://#{DOMAIN}#{PORT_SUFFIX}"

authenticateUser = (profile, done) ->
  passport_id = profile.identifier or (profile.provider + profile.id)
  UserPassport
    .findOne(passport_id: passport_id)
    .populate('user')
    .exec (error, userPassport) ->
      return done error if error
      user = userPassport?.user
      return done null, userPassport if user
      userPassport ?= new UserPassport()
      # Create new user from passport profile.
      user = new User
        name: profile.displayName or profile.username
      user.email = profile.emails[0].value if profile.emails?[0]
      user.save (error) ->
        return done error if error
        userPassport.profile = profile
        userPassport.user = user._id
        userPassport.save (error) ->
          done error, userPassport
          #res.redirect('/user/' + user.pub_id + '/edit');

authenticationSuccessfulAPI = (req, res) ->
  throw new Error('authenticationSuccessfulAPI: req.user array') if Array.isArray req.user
  res.redirect '/closeme'

authenticationSuccessful = (req, res) ->
  throw new Error('authenticationSuccessful: req.user array') if Array.isArray req.user
  res.redirect '/'

#passport.use new LocalStrategy(
#  usernameField: 'email'
#  passwordField: 'password'
#, (email, password, done) ->
#  User.findOne
#    _email: email
#  , (err, user) ->
#    return done(err)  if err
#    return done(null, false)  unless user
#    return done(null, false)  unless user.authenticate(password)
#    done null, user
#)

for i in ["", "/v1"]
  passport.use "facebook#{i}", new FacebookStrategy(
    clientID: config.FACEBOOK_APP_ID
    clientSecret: config.FACEBOOK_APP_SECRET
    callbackURL: "#{URL_PREFIX}#{i}/auth/facebook/callback"
  , (accessToken, refreshToken, profile, done) ->
    profile.auth = { accessToken, refreshToken }
    authenticateUser profile, done
  )
  passport.use "google#{i}", new GoogleStrategy(
    returnURL: "#{URL_PREFIX}#{i}/auth/google/return"
    realm: URL_PREFIX + '/'
  , (identifier, profile, done) ->
    # passport-oauth doesn't supply provider or id.
    profile.identifier = identifier  # Old storage
    profile.auth = { identifier }    # New unified auth
    authenticateUser profile, done
  )
  passport.use "twitter#{i}", new TwitterStrategy(
    consumerKey: config.TWITTER_APP_KEY
    consumerSecret: config.TWITTER_APP_SECRET
    callbackURL: "#{URL_PREFIX}#{i}/auth/twitter/callback"
  , (token, tokenSecret, profile, done) ->
    profile.auth = { token, tokenSecret }
    authenticateUser profile, done
  )

passport.serializeUser (userPassport, done) ->
  done null, userPassport.id

passport.deserializeUser (id, done) ->
  UserPassport
    .findOne(_id: id)
    .populate('user')
    .exec (error, userPassport) ->
      done error, userPassport

app.use express.logger(format: '[:isodate] :status :response-time ms :method :url :referrer')
app.disable 'x-powered-by'
app.use express.compress()
app.use stylus.middleware(
  src: __dirname + '/stylus'
  dest: __dirname + '/public'
)
app.use express.static(__dirname + '/public')
app.set 'views', __dirname + '/views'
app.set 'view engine', 'jade'
app.use (req, res, next) ->
  req.rawBody = ''
  # req.setEncoding('utf8')
  req.on 'data', (chunk) -> req.rawBody += chunk
  next()
app.use express.bodyParser()
app.use express.cookieParser(config.SESSION_SECRET)
app.use express.session(
  cookie:
    maxAge: 4 * 7 * 24 * 60 * 60 * 1000

  store: sessionStore
)
app.use passport.initialize()
app.use passport.session()
app.use express.methodOverride()
app.use (req, res, next) ->
  # Enable Chrome Frame if installed.
  res.setHeader 'X-UA-Compatible', 'chrome=1'
  next()
app.use routes.defaultParams

#
#// We can delay certain resources for debugging purposes.
#app.use(function(req, res, next) {
#  var delay = 0;
#  if (req.path.match('nice.png')) delay = 3000;
#  if (req.path.match('heightdetail1.jpg')) delay = 6000;
#  setTimeout(function() {
#    next();
#  }, delay);
#});
#

app.use app.router

app.use (req, res) ->
  res.send 404, "Sorry, we couldn't find a page with this address."

app.configure 'development', ->
  app.use (err, req, res, next) ->
    console.error err
    res.json 500,
      error: "Internal Server Error"
      call_stack: err.stack.split('\n')

app.configure 'production', ->
  app.use (err, req, res, next) ->
    console.error err
    res.json 500,
      error: "Internal Server Error"

mongoose.connect config.MONGOOSE_URL

loadUrlUser = (req, res, next) ->
  User
    .findOne(pub_id: req.params.idUser)
    .exec (error, urlUser) ->
      if error then done error
      else
        if urlUser
          urlUser.isAuthenticated = req.user?.user?.id is urlUser.id
          req.urlUser = urlUser
          next()
        else
          res.send 404


loadUrlTrackInternal = (find, req, res, next) ->
  find
    .populate('user')
    .populate('env')
    .populate('parent', {'pub_id':1, 'name':1})
    .exec (error, urlTrack) ->
      if error then return next error
      unless urlTrack then return res.send 404
      urlTrack.isAuthenticated = req.user?.user?.id is urlTrack.user.id
      req.urlTrack = urlTrack
      unless urlTrack.env then return next()
      Car
        .find()
        .where('_id')
        .in(urlTrack.env.cars)
        .exec (error, cars) ->
          if error then return next error
          # Horrible workaround because we can't populate env.cars directly.
          # See Environment model for the rest of the hack.
          req.urlTrack.env.populatedCars = cars
          next()

loadUrlTrack = (req, res, next) ->
  find = Track.findOne
    pub_id: req.params.idTrack
  loadUrlTrackInternal find, req, res, next

loadUrlTrackIncDrive = (req, res, next) ->
  find = Track.findOneAndUpdate
    pub_id: req.params.idTrack
  ,
    $inc: { count_drive: 1 }
  loadUrlTrackInternal find, req, res, next

loadUrlCar = (req, res, next) ->
  Car
    .findOne(pub_id: req.params.idCar)
    .populate('user')
    .exec (error, urlCar) ->
      if error then return next error
      unless urlCar then return res.send 404
      urlCar.isAuthenticated = req.user?.user?.id is urlCar.user.id
      req.urlCar = urlCar
      next()

loadUrlRun = (req, res, next) ->
  Run
    .findOne(pub_id: req.params.idRun)
    .populate('user')
    .populate('car')
    .populate('track')
    .exec (error, urlRun) ->
      if error then return next error
      unless urlRun then return res.send 404
      urlRun.isAuthenticated = req.user?.user?.id is urlRun.user.id
      req.urlRun = urlRun
      next()

editTrack = (req, res, next) ->
  unless req.urlTrack.isAuthenticated
    return res.send 403
  # TODO: mark just the track as editable, not the whole request.
  req.editing = true
  next()

editCar = (req, res, next) ->
  unless req.urlCar.isAuthenticated
    return res.send 403
  req.editing = true
  next()

editUser = (req, res, next) ->
  unless req.urlUser.isAuthenticated
    return res.send 403
  req.editing = true
  next()

app.get    '/v1/auth/facebook', passport.authenticate('facebook/v1')
app.get    '/v1/auth/facebook/callback', passport.authenticate('facebook/v1',
  failureRedirect: '/login?popup=1'
), authenticationSuccessfulAPI
app.get    '/v1/auth/google', passport.authenticate('google/v1')
app.get    '/v1/auth/google/return', passport.authenticate('google/v1',
  failureRedirect: '/login?popup=1'
), authenticationSuccessfulAPI
app.get    '/v1/auth/twitter', passport.authenticate('twitter/v1')
app.get    '/v1/auth/twitter/callback', passport.authenticate('twitter/v1'), authenticationSuccessfulAPI

app.get    '/v1/auth/logout', (req, res) ->
  req.logOut()
  res.json status: "ok"

require('./api') app, passport

app.get    '/auth/facebook', passport.authenticate('facebook')
app.get    '/auth/facebook/callback', passport.authenticate('facebook',
  failureRedirect: '/login'
), authenticationSuccessful
app.get    '/auth/google', passport.authenticate('google')
app.get    '/auth/google/return', passport.authenticate('google',
  failureRedirect: '/login'
), authenticationSuccessful
app.get    '/auth/twitter', passport.authenticate('twitter')
app.get    '/auth/twitter/callback', passport.authenticate('twitter',
  failureRedirect: '/login'
), authenticationSuccessful

app.get    '/logout', (req, res) ->
  req.logOut()
  res.redirect '/'

app.get    '/closeme', routes.closeme

app.get    '/', routes.unified
app.get    '/about', routes.unified
app.get    '/track/:idTrack/drive', routes.unified
app.get    '/track/:idTrack/edit', routes.unified

app.get    '/requirements', routes.requirements
app.get    '/login', routes.login
app.get    '/user/confirm', routes.userconfirm
app.get    '/user/:idUser', loadUrlUser, routes.user
app.get    '/user/:idUser/edit', loadUrlUser, editUser, routes.user
app.post   '/user/:idUser/save', loadUrlUser, editUser, routes.userSave
app.get    '/recenttracks', routes.recentTracks
app.get    '/track/:idTrack', loadUrlTrack, routes.track
app.get    '/car/:idCar', loadUrlCar, routes.car
app.get    '/car/:idCar/json', loadUrlCar, routes.carJson
app.get    '/car/:idCar/json/edit', loadUrlCar, editCar, routes.carJson
app.post   '/car/:idCar/json/save', loadUrlCar, editCar, routes.carJsonSave
app.get    '/run/:idRun', loadUrlRun, routes.run
app.post   '/run/new', routes.runSave
app.get    '/run/:idRun/replay', loadUrlRun, routes.runReplay
app.get    '/x/:idTrack/:idCar/top', loadUrlTrack, loadUrlCar, routes.top
app.post   '/metrics', routes.metricsSave

#
#app.post('/login',
#    passport.authenticate('local', { failureRedirect: '/login?status=failed' }),
#    authenticationSuccessful
#);
#

# Backward compatibility.
app.get '/drive', (req, res) ->
  res.redirect '/x/Preview/Arbusu/drive', 301

app.post '/paypal/ipn', handleIPN

server = http.createServer(app)
# io = socketio.listen(server)
server.listen PORT
log "Server listening on port #{PORT} in #{app.settings.env} mode"


# TODO: Mirror http api over socket.io.

# if NODE_ENV is 'production'
#   io.set 'log level', 1
# else
#   io.set 'log level', 2

# showNumberConnected = ->
#   clients = io.sockets.clients()
#   numConnected = clients.length
#   log "Connected sockets: #{numConnected}"

# io.set 'authorization', (data, accept) ->
#   # http://www.danielbaulig.de/socket-ioexpress/
#   return accept('No cookie transmitted.', false) unless data.headers.cookie
#   data.cookie = cookie.parse(data.headers.cookie)
#   sid = data.cookie['connect.sid']
#   return accept('No session id found.', false) unless sid
#   data.sessionID = sid.substring(2, 26)
#   # save the session store to the data object
#   # (as required by the Session constructor)
#   data.sessionStore = sessionStore
#   sessionStore.get data.sessionID, (err, session) ->
#     if err
#       accept err, false
#     else unless session
#       accept 'No session', false
#     else
#       # create a session object, passing data as request and our
#       # just acquired session data
#       Session = connect.middleware.session.Session
#       data.session = new Session(data, session)
#       # TODO: accept fast, before deserialization?
#       passport.deserializeUser data.session.passport.user, (err, userPassport) ->
#         if err then accept 'passport error: ' + err, false
#         else
#           data.session.user = userPassport.user
#           data.session.userPassport = userPassport
#           accept null, true

# db.bind 'cars'
# db.bind 'environments'
# db.bind 'tracks'
# db.bind 'users'

# publicCar = (car) ->
#   id: car.pub_id
#   name: car.name
#   config: car.config

# publicUserBasic = (user) ->
#   id: user.pub_id
#   name: user.name

# getPublicEnv = (_id, cb) ->
#   db.environments.findOne {_id}, (err, env) ->
#     return cb err if err?
#     db.cars.find({ _id: { $in: env.cars } }).toArray (err, cars) ->
#       return cb err if err?
#       cb null,
#         id: env.pub_id
#         name: env.name
#         cars: (publicCar(car) for car in cars)
#         scenery: env.scenery
#         terrain: env.terrain

# getPublicTrackPubId = (pub_id, cb) ->
#   db.tracks.findOne {pub_id}, (err, track) ->
#     return cb err if err?
#     getPublicEnv track.env, (err, env) ->
#       return cb err if err?
#       db.users.findOne track.user, (err, user) ->
#         return cb err if err?
#         cb null,
#           id: track.pub_id
#           name: track.name
#           config: track.config
#           env: env
#           user: publicUserBasic user
#           published: track.published

# io.of('/api').on 'connection', (socket) ->
#   session = socket.handshake.session
#   wireId = socket.id
#   tag = (if session.user then " #{session.user.pub_id}" else "")
#   do ->
#     isodate = getIsodate()
#     console.log "[#{isodate}] #{wireId} connected" + tag
#   #showNumberConnected()

#   socket.on 'sync', (data, callback) ->
#     switch data.method
#       when 'create'
#         callback 'create not implemented'
#       when 'read'
#         switch data.urlRoot
#           when 'track'
#             getPublicTrackPubId data.model.id, (err, track) ->
#               return callback err if err?
#               callback null, track
#       when 'update'
#         switch data.urlRoot
#           when 'track'
#             db.tracks.findOne { pub_id: data.model.id }, (err, track) ->
#               return callback err if err?
#               unless track?
#                 return callback 404
#               unless track.user.equals session.user._id
#                 return callback 403
#               track.config = data.model.config
#               track.name = data.model.name
#               track.published = data.model.published
#               track.modified = new Date()
#               db.tracks.save track, (err) ->
#                 callback err, {}
#                 isodate = getIsodate()
#                 console.log "[#{isodate}] Track #{track.pub_id} saved by #{session.user.pub_id}"
#       when 'delete'
#         callback 'delete not implemented'
#     return

#   ###
#   # Stuff a custom storage object into the socket.
#   socket.hackyStore = {}
#   socket.on 'c2s', (data) ->

#     #console.log('Update from ' + wireId + tag);
#     if data.config

#       # TODO: Find a cleaner way of signaling that cars are remote?
#       data.config.isRemote = true
#       socket.hackyStore['config'] = data.config
#     if data.carstate
#       clients = io.sockets.clients()
#       clients.forEach (client) ->
#         if client.id isnt wireId
#           seen = client.hackyStore['seen'] or (client.hackyStore['seen'] = {})
#           unless seen[wireId]
#             seen[wireId] = true
#             client.emit 'addcar',
#               wireId: wireId
#               config: socket.hackyStore['config']

#           client.volatile.emit 's2c',
#             wireId: wireId
#             carstate: data.carstate

#   socket.on 'disconnect', ->
#     showNumberConnected()
#     console.log wireId + ' disconnected' + tag
#     clients = io.sockets.clients()
#     clients.forEach (client) ->
#       if client.id isnt wireId
#         seen = client.hackyStore['seen'] or (client.hackyStore['seen'] = {})
#         if wireId of seen
#           delete seen[wireId]

#           client.emit 'deletecar',
#             wireId: wireId
#   ###

#   socket.on 'error', (data) ->
#     isodate = getIsodate()
#     console.log "[#{isodate}] Error from #{wireId}: #{data.msg}"
