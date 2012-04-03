/* Copyright (c) 2009, Mamta Singh. See README for details. */
package model
{
	import flash.events.AsyncErrorEvent;
	import flash.events.ErrorEvent;
	import flash.events.EventDispatcher;
	import flash.events.IOErrorEvent;
	import flash.events.NetStatusEvent;
	import flash.events.SecurityErrorEvent;
	import flash.net.NetConnection;
	import flash.net.NetStream;
	import flash.net.ObjectEncoding;
	import flash.net.SharedObject;
	import mx.collections.ArrayCollection;
	
	public class Connector extends EventDispatcher
	{
		//--------------------------------------
		// CLASS CONSTANTS
		//--------------------------------------
		
		public static const IDLE:String      = "idle";
		public static const CONNECTING:String= "connecting";
		public static const CONNECTED:String = "connected";
		public static const OUTBOUND:String  = "outbound";
		public static const INBOUND:String   = "inbound";
		public static const ACTIVE:String    = "active";
		public static const allowedParameters:Array = ["signupURL", "gatewayURL", "sipURL", "authName", "authPass", "displayName", "targetURL", "codecs"];
		private static const MAX_HISTORY_SIZE:uint = 20;
		
		//--------------------------------------
		// PRIVATE PROPERTIES
		//--------------------------------------
		
		/**
		 * Internal property to store the connector's state.
		 */
		private var _currentState:String = IDLE;
		
		/**
		 * The local shared object to store the configuration properties.
		 */
		private var so:SharedObject;
		
		/**
		 * The current index in the call history list.
		 */
		private var historyIndex:int = -1;
		
		/**
		 * The unique NetConnection that is used to connect to the gateway service.
		 */
		private var nc:NetConnection;
		
		/**
		 * The two NetStream objects: one for playing remote audio and video, and other
		 * to publish out own audio and video.
		 */
		private var _play:NetStream, _publish:NetStream;
		
		//--------------------------------------
		// PUBLIC PROPERTIES
		//--------------------------------------
		
		[Bindable]
		public var signupURL:String;
		[Bindable]
		public var gatewayURL:String;
		[Bindable]
		public var sipURL:String;	
		[Bindable]
		public var authName:String;
		[Bindable]
		public var authPass:String;
		[Bindable]
		public var displayName:String; 
		[Bindable]
		public var targetURL:String;
		[Bindable]
		public var status:String;
		[Bindable]
		public var remember:Boolean = false;
		[Bindable]
		public var codecs:String = null;
		[Bindable]
		public var selectedAudio:String = null;
		[Bindable]
		public var selectedVideo:String = null;
		
		//--------------------------------------
		// CONSTRUCTOR
		//--------------------------------------
		
		/**
		 * Constructing a new connector object just loads the configuration from
		 * local shared object if available.
		 */
		public function Connector()
		{
			so = SharedObject.getLocal("phone");
			codecs = "pcma pcmu";
//			codecs = "wideband narrowband ulaw alaw dtmf flv";
		}
		
		//--------------------------------------
		// GETTERS/SETTERS
		//--------------------------------------
		
		[Bindable]
		/**
		 * The currentState property represents connector's state as mentioned before.
		 * Changing the state also updates the status property to reflect the user
		 * understandable status message such as "Connecting..."
		 */
		public function get currentState():String
		{
			return _currentState;
		}
		public function set currentState(value:String):void
		{
			var oldValue:String = _currentState;
			_currentState = value;
			
			switch (value) {
				case IDLE:
					if (oldValue == null)
						status = _("Initializing") + "...";
					else
						status = _("Disconnected from service");
					stopPublishPlay();
					break;
				case CONNECTING:
					status = _("Connecting") + "...";
					break;
				case CONNECTED:
					invite(targetURL);
					if (oldValue == CONNECTING)
						status = _("Logged in as {0}", sipURL);
					else if (oldValue == OUTBOUND)
						status = _("Call cancelled");
					else
						status = _("Call terminated");
					stopPublishPlay();
					break;
				case OUTBOUND:
				//	historyAdd(targetURL);
					status = _("Calling out {0}", targetURL) + "...";
					break;
				case INBOUND:
				//	historyAdd(targetURL);
					status = _("Call from {0}", targetURL) + "...";
					break;
				case ACTIVE:
					status = _("Call connected");
					// publish and play
					startPublishPlay();
					break;
			}
		}
		
		/**
		 * The read-only playStream property gives access to the currently playing
		 * NetStream which plays audio video from the remote party.
		 */
		public function get playStream():NetStream
		{
			return _play;
		}
		
		/**
		 * The read-only publishStream property gives access to the currently published
		 * NetStream which publishes audio video of the local party.
		 */
		public function get publishStream():NetStream
		{
			return _publish;
		}
		
		/**
		 * The read write property to set the bufferTime.
		 */
		public function get bufferTime():Number
		{
			return _play != null ? _play.bufferTime : 0.0;
		}
		public function set bufferTime(value:Number):void
		{
			if (_play != null) {
				_play.bufferTime = value;
			}
		}
		
		//--------------------------------------
		// PUBLIC METHODS
		//--------------------------------------
		
		public function connect(gatewayURL:String=null, sipURL:String=null, authName:String=null, authPass:String=null, displayName:String=null):void
		{
			if (gatewayURL != null && sipURL != null) {
				this.gatewayURL = gatewayURL;
				this.sipURL = sipURL;
				this.authName = authName;
				this.authPass = authPass;
				this.displayName = displayName;
			}
			trace("login " + this.gatewayURL + "," + this.sipURL + "," + this.authName + "," + this.displayName);

			if (this.gatewayURL != null && this.sipURL != null)
				connectInternal();
		}
		public function disconnect():void
		{
			disconnectInternal();
		}
		
		public function invite(sipURL:String):void
		{
			targetURL = sipURL;
			inviteInternal();
		}
		
		public function bye():void
		{
			if (currentState == OUTBOUND || currentState == ACTIVE) { 
				currentState = CONNECTED;
				if (nc != null) {
					nc.call("bye", null);
				}
			}
			//TODO: doIncomingCall();
		}

		public function accepted(audioCodec:String=null, videoCodec:String=null):void
		{
			trace("accepted audioCodec=" + audioCodec + " videoCodec=" + videoCodec);
			if (currentState == OUTBOUND || currentState == INBOUND) {
				this.selectedAudio = audioCodec;
				this.selectedVideo = videoCodec;
				currentState = ACTIVE;
			}
		}
	
		public function rejected(reason:String):void
		{
			trace("rejected reason=" + reason);
			if (currentState == OUTBOUND) {
				currentState = CONNECTED;
				this.status = _("reason") + ": " + reason;
			}
		}
		
		public function byed():void
		{
			trace("byed");
			if (currentState == ACTIVE)
				currentState = CONNECTED;
		}
		
		/**
		 * When the remote side has put us on hold or unhold.
		 */
		public function holded(value:Boolean):void
		{
			trace("holded " + value);
			if (currentState == ACTIVE)
				this.status = value ? _("you are put on hold") : _("you are put off hold");
		}

		public function ringing(value:String):void
		{
			trace("ringing " + value);
			if (currentState == OUTBOUND)
				this.status = _("Ringing: " + value);
		}

		//--------------------------------------
		// PRIVATE METHODS
		//--------------------------------------
		
		/**
		 * Internal method to actually do connection to the gateway service.
		 */
		private function connectInternal():void
		{
			if (currentState == IDLE) {
				currentState = CONNECTING;
				
				if (nc != null) {
					nc.close();
					nc = null; _play = _publish = null;
				}
				
				nc = new NetConnection();
				//nc.objectEncoding = ObjectEncoding.AMF0; // This is MUST!
				nc.client = this;
				nc.addEventListener(NetStatusEvent.NET_STATUS, netStatusHandler, false, 0, true);
				nc.addEventListener(IOErrorEvent.IO_ERROR, errorHandler, false, 0, true);
				nc.addEventListener(SecurityErrorEvent.SECURITY_ERROR, errorHandler, false, 0, true);
				nc.addEventListener(AsyncErrorEvent.ASYNC_ERROR, errorHandler, false, 0, true);
				
				var url:String = this.gatewayURL + "/" + (this.sipURL.substr(0, 4) == "sip:" ? this.sipURL.substr(4) : this.sipURL); 
				trace('connect() ' + url);
				nc.connect(url, this.authName, this.authPass, this.displayName);
			}
		}
		
		/**
		 * When the connection status is received take appropriate actions.
		 * For example, when the connection is successful, create the play and publish 
		 * streams. The method also updates the local state.
		 */
		private function netStatusHandler(event:NetStatusEvent):void 
		{
			trace('netStatusHandler() ' + event.type + ' ' + event.info.code);
			switch (event.info.code) {
			case 'NetConnection.Connect.Success':
				_publish = new NetStream(nc);
				_play = new NetStream(nc);
				_play.bufferTime = 0;
				_publish.addEventListener(NetStatusEvent.NET_STATUS, netStatusHandler, false, 0, true);
				_play.addEventListener(NetStatusEvent.NET_STATUS, netStatusHandler, false, 0, true);
				_publish.client = {}
				_play.client = {}
				if (currentState == CONNECTING)
					currentState = CONNECTED;
				invite(targetURL);
				break;
			case 'NetConnection.Connect.Failed':
			case 'NetConnection.Connect.Rejected':
			case 'NetConnection.Connect.Closed':
				if (nc != null)
					nc.close();
				nc = null; _play = _publish = null;
				currentState = IDLE;
				if ('description' in event.info)
					this.status = _("reason") + ": " + event.info.description;
				break;
			}
		}
		
		/**
		 * When there is an error in the connection, close the connection and
		 * any associated stream.
		 */
		private function errorHandler(event:ErrorEvent):void 
		{
			trace('errorHandler() ' + event.type + ' ' + event.text);
			if (nc != null)
				nc.close();
			nc = null; _play = _publish = null;
			currentState = IDLE;
			this.status = _("reason") + ": " + event.type + " " + event.text;
		}
		
		/**
		 * Internal method to disconnect with the gateway service and to
		 * close the connection.
		 */
		private function disconnectInternal():void
		{
			currentState = IDLE;
			if (nc != null) {
				nc.close();
				nc = null; _play = _publish = null;
			}
		}
		
		/**
		 * Internal method to invoke the outbound call invitation RPC.
		 */
		private function inviteInternal():void
		{
			if (currentState == CONNECTED) {
				
				if (nc != null) {
					currentState = OUTBOUND;
					var args:Array = ["invite", null, this.targetURL];
					for each (var part:String in this.codecs.split(" ")) {
						args.push(part);
					}
					nc.call.apply(nc, args);
					//nc.call("invite", null, this.targetURL, "wideband", "narrowband", "pcmu", "pcma", "alaw", "ulaw", "dtmf", "h264", "flv");
				}
				else {
					this.status = _("Must be connected to invite");
				}
			}
		}
		
		/**
		 * When the call is active, publish local stream and play remote stream.
		 */
		private function startPublishPlay():void
		{
			trace('startPublishPlay');
			if (_publish != null)
				_publish.publish("local");
			if (_play != null)
				_play.play("remote");
		}
		
		/**
		 * When the call is terminated close both local and remote streams.
		 */
		private function stopPublishPlay():void
		{
			trace('stopPublishPlay');
			if (_publish != null)
				_publish.close();
			if (_play != null)
				_play.close();
		}
	}
}
