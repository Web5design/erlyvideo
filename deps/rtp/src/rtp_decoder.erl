%%% @author     Max Lapshin <max@maxidoors.ru> [http://erlyvideo.org]
%%% @copyright  2010-2011 Max Lapshin
%%% @doc        RTP decoder module
%%% @end
%%% @reference  See <a href="http://erlyvideo.org/ertp" target="_top">http://erlyvideo.org</a> for common information.
%%% @end
%%%
%%% This file is part of erlang-rtp.
%%%
%%% erlang-rtp is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlang-rtp is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlang-rtp.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(rtp_decoder).
-author('Max Lapshin <max@maxidoors.ru>').

-include_lib("erlmedia/include/h264.hrl").
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").
-include_lib("erlmedia/include/sdp.hrl").
-include("rtp.hrl").
-include("log.hrl").
-include_lib("eunit/include/eunit.hrl").

-record(h264_buffer, {
  time,
  h264,
  buffer,
  flavor
}).

-export([init/1, decode/2, sync/2, rtcp_rr/1, rtcp_sr/1, rtcp/2, config_frame/1]).

init(#stream_info{codec = Codec, timescale = Scale} = Stream) ->
  #rtp_state{codec = Codec, stream_info = Stream, timescale = Scale}.

config_frame(#rtp_state{stream_info = Stream}) ->
  video_frame:config_frame(Stream).


sync(#rtp_state{} = RTP, Headers) ->
  Seq = proplists:get_value("seq", Headers),
  Time = proplists:get_value("rtptime", Headers),
  ?D({sync, Headers}),
  RTP#rtp_state{wall_clock = 0, timecode = list_to_integer(Time), sequence = list_to_integer(Seq)}.

decode(_, #rtp_state{timecode = TC, wall_clock = Clock} = RTP) when TC == undefined orelse Clock == undefined ->
  % ?D({unsynced, RTP}),
  {ok, RTP, []};

decode(<<_:16, Sequence:16, _/binary>> = Data, #rtp_state{sequence = undefined} = RTP) ->
  decode(Data, RTP#rtp_state{sequence = Sequence});

decode(<<_:16, OldSeq:16, _/binary>>, #rtp_state{sequence = Sequence} = RTP) when OldSeq < Sequence ->
  ?D({drop_sequence, Sequence}),
  {ok, RTP, []};

decode(<<2:2, 0:1, _Extension:1, 0:4, _Marker:1, _PayloadType:7, Sequence:16, Timecode:32, _StreamId:32, Data/binary>>, #rtp_state{} = RTP) ->
  decode(Data, RTP#rtp_state{sequence = (Sequence + 1) rem 65536}, Timecode).


decode(<<AULength:16, AUHeaders:AULength/bitstring, AudioData/binary>>, #rtp_state{codec = aac} = RTP, Timecode) ->
  decode_aac(AudioData, AUHeaders, RTP, Timecode, []);
  
decode(Body, #rtp_state{codec = h264, buffer = Buffer} = RTP, Timecode) ->
  DTS = timecode_to_dts(RTP, Timecode),
  {ok, Buffer1, Frames} = decode_h264(Body, Buffer, DTS),
  {ok, RTP#rtp_state{buffer = Buffer1}, Frames};

decode(Body, #rtp_state{stream_info = #stream_info{codec = Codec, content = Content} = Info} = RTP, Timecode) ->
  DTS = timecode_to_dts(RTP, Timecode),
  Frame = #video_frame{
    content = Content,
    dts     = DTS,
    pts     = DTS,
    body    = Body,
	  codec	  = Codec,
	  flavor  = frame,
	  sound	  = video_frame:frame_sound(Info)
  },
  {ok, RTP, [Frame]}.
  

decode_h264(Body, undefined, DTS) ->
  decode_h264(Body, #h264_buffer{}, DTS);

decode_h264(_Body, #h264_buffer{time = undefined} = RTP, DTS) ->
  {ok, RTP#h264_buffer{time = DTS}, []}; % Here we are entering sync-wait state which will last till current inteleaved frame is over

decode_h264(_Body, #h264_buffer{time = OldDTS, h264 = undefined} = RTP, DTS) when OldDTS =/= DTS ->
  {ok, RTP#h264_buffer{time = DTS, h264 = h264:init(), buffer = <<>>}, []};

decode_h264(_Body, #h264_buffer{time = DTS, h264 = undefined} = RTP, DTS) ->
  {ok, RTP, []};

decode_h264(Body, #h264_buffer{h264 = H264, time = DTS, buffer = Buffer, flavor = Flavor} = RTP, DTS) ->
  {H264_1, Frames} = h264:decode_nal(Body, H264),
  Buf1 = lists:foldl(fun(#video_frame{body = AVC}, Buf) -> <<Buf/binary, AVC/binary>> end, Buffer, Frames),
  Flavor1 = case Frames of
    [#video_frame{flavor = Fl}|_] -> Fl;
    [] -> Flavor
  end,
  {ok, RTP#h264_buffer{h264 = H264_1, buffer = Buf1, flavor = Flavor1}, []};
  
decode_h264(Body, #h264_buffer{h264 = OldH264, time = OldDTS, buffer = Buffer, flavor = Flavor} = RTP, DTS) when OldDTS < DTS ->
  OldH264#h264.buffer == <<>> orelse erlang:error({non_decoded_h264_left, OldH264}),

  Frame = #video_frame{
    content = video,
    codec = h264,
    body = Buffer,
    flavor = Flavor,
    dts = DTS, 
    pts = DTS
  },

  {ok, RTP1, []} = decode_h264(Body, RTP#h264_buffer{h264 = h264:init(), time = DTS, buffer = <<>>}, DTS),
  {ok, RTP1, [Frame]}.


decode_aac(<<>>, <<>>, RTP, _, Frames) ->
  {ok, RTP, lists:reverse(Frames)};

decode_aac(AudioData, <<AUSize:13, _Delta:3, AUHeaders/bitstring>>, RTP, Timecode, Frames) ->
  <<Body:AUSize/binary, Rest/binary>> = AudioData,
  DTS = timecode_to_dts(RTP, Timecode),
  Frame = #video_frame{
    content = audio,
    dts     = DTS,
    pts     = DTS,
    body    = Body,
	  codec	  = aac,
	  flavor  = frame,
	  sound	  = {stereo, bit16, rate44}
  },
  decode_aac(Rest, AUHeaders, RTP, Timecode + 1024, [Frame|Frames]).

timecode_to_dts(#rtp_state{timescale = Scale, timecode = BaseTimecode, wall_clock = WallClock}, Timecode) ->
  WallClock + (Timecode - BaseTimecode)/Scale.


rtcp_sr(<<2:2, 0:1, _Count:5, ?RTCP_SR, _Length:16, _StreamId:32, NTP:64, Timecode:32, _PacketCount:32, _OctetCount:32, _Rest/binary>>) ->
  {NTP, Timecode}.



rtcp(<<_, ?RTCP_SR, _/binary>> = SR, #rtp_state{timecode = TC} = RTP) when TC =/= undefined->
  {NTP, _Timecode} = rtcp_sr(SR),
  RTP#rtp_state{last_sr = NTP};

rtcp(<<_, ?RTCP_SR, _/binary>> = SR, #rtp_state{} = RTP) ->
  {NTP, Timecode} = rtcp_sr(SR),
  WallClock = round((NTP / 16#100000000 - ?YEARS_70) * 1000),
  RTP#rtp_state{wall_clock = WallClock, timecode = Timecode, last_sr = NTP};

rtcp(<<_, ?RTCP_RR, _/binary>>, #rtp_state{} = RTP) ->
  RTP.



rtcp_rr(#rtp_state{last_sr = undefined} = RTP) ->
  rtcp_rr(RTP#rtp_state{last_sr = 0});

rtcp_rr(#rtp_state{stream_info = #stream_info{stream_id = StreamId}, sequence = Seq, last_sr = LSR} = RTP) ->
  Count = 0,
  Length = 16,
  FractionLost = 0,
  LostPackets = 0,
  MaxSeq = case Seq of
    undefined -> 0;
    MS -> MS
  end,
  Jitter = 0,
  DLSR = 0,
  ?D({send_rr, StreamId, Seq, LSR, MaxSeq}),
  {RTP, <<2:2, 0:1, Count:5, ?RTCP_RR, Length:16, StreamId:32, FractionLost, LostPackets:24, MaxSeq:32, Jitter:32, LSR:32, DLSR:32>>}.



%%%%%%%%%  Tests %%%%%%%%%

decode_video_h264_test() ->
  #media_info{video = [Video]} = sdp:decode(wirecast_sdp()),
  ?assertMatch({ok, #rtp_state{}, [
    
  ]}, decode(wirecast_video_rtp(), rtp_decoder:init(Video))).

decode_audio_aac_test() ->
  #media_info{audio = [Audio]} = sdp:decode(wirecast_sdp()),
  Decoder = rtp_decoder:rtcp_sr(wirecast_sr1(), rtp_decoder:init(Audio)),
  ?assertMatch({ok, #rtp_state{}, [
    #video_frame{codec = aac, dts = 1300205206513.9092},
    #video_frame{codec = aac, dts = 1300205206537.182},
    #video_frame{codec = aac, dts = 1300205206560.4546}
  ]}, decode(wirecast_audio_rtp(), Decoder)).


decode_sr_test_() ->
  [ ?_assertEqual({15071873493697523644,338381}, rtcp_sr(wirecast_sr1())),
    ?_assertEqual({15071873493656068605,913426}, rtcp_sr(wirecast_sr2())),
    ?_assertMatch(#rtp_state{
      wall_clock = 1300205206607,
      timecode = 338381
    }, rtcp(wirecast_sr1(), #rtp_state{}))
  ].




wirecast_sdp() ->
<<"v=0
o=- 2070800592 2070800592 IN IP4 127.0.0.0
s=Wirecast
c=IN IP4 127.0.0.1
t=0 0
a=range:npt=now-
m=audio 0 RTP/AVP 96
a=rtpmap:96 mpeg4-generic/44100/2
a=fmtp:96 profile-level-id=15;mode=AAC-hbr;sizelength=13;indexlength=3;indexdeltalength=3;config=1210
a=control:trackid=1
m=video 0 RTP/AVP 97
a=rtpmap:97 H264/90000
a=fmtp:97 packetization-mode=1;profile-level-id=4D401E;sprop-parameter-sets=J01AHqkYPBf8uANQYBBrbCte98BA,KN4JyA==
a=cliprect:0,0,360,480
a=framesize:97 480-360
b=AS:1372
a=control:trackid=2">>.



wirecast_video_rtp() ->
  <<128,97,70,186,0,13,251,202,0,70,87,111,60,129,
                               228,17,1,212,184,112,147,252,5,151,0,187,95,163,
                               215,254,22,187,185,253,229,148,100,63,132,38,255,
                               35,32,129,245,180,116,61,112,224,105,84,190,140,
                               19,67,94,248,21,250,182,159,255,5,250,66,22,59,
                               220,4,34,112,211,23,106,137,3,79,240,238,1,55,
                               147,130,211,86,218,22,201,207,213,36,36,138,222,
                               245,20,65,39,148,108,26,124,6,49,230,212,214,116,
                               219,36,211,152,102,17,112,67,195,94,95,206,230,
                               75,108,119,239,104,4,0,65,138,67,116,113,191,170,
                               214,242,31,6,201,206,192,183,75,195,168,21,215,
                               109,15,224,183,67,244,139,150,127,181,135,31,234,
                               27,96,45,209,32,23,210,34,84,254,198,191,184,166,
                               215,17,58,104,109,217,118,159,60,36,87,160,58,91,
                               112,74,228,144,174,176,151,152,222,216,80,101,
                               197,39,240,135,130,13,184,173,39,110,219,180,226,
                               100,41,64,70,58,147,209,3,217,101,36,148,30,66,
                               211,29,143,105,158,29,192,139,68,127,248,81,91,
                               155,174,67,227,184,165,102,243,161,60,240,201,
                               132,8,205,234,87,192,140,108,47,205,29,157,164,
                               94,207,195,185,161,113,197,162,53,95,166,205,221,
                               233,193,12,34,115,117,6,2,85,233,151,163,167,198,
                               205,116,60,118,6,223,194,251,72,156,74,98,246,15,
                               236,209,76,207,118,200,71,109,217,231,75,109,59,
                               112,230,3,119,1,97,38,169,166,50,133,74,52,226,
                               244,219,134,112,166,99,29,174,15,85,143,100,71,
                               117,48,202,103,61,210,188,100,63,164,217,88,15,
                               63,251,221,219,27,0,74,50,198,75,200,131,183,124,
                               127,195,185,8,58,61,211,119,109,191,113,192,76,
                               119,13,187,183,231,195,184,36,206,57,87,118,191,
                               190,120,183,157,41,101,254,24,36,106,39,108,201,
                               40,57,48,136,231,4,213,179,93,215,145,68,59,56,
                               151,27,179,253,186,85,118,192,253,35,188,126,40,
                               230,74,74,31,135,114,201,175,251,77,248,126,58,
                               200,196,93,182,42,69,74,127,158,30,81,220,55,225,
                               151,95,236,36,114,205,255,6,32,191,105,124,86,18,
                               153,14,212,42,146,136,28,134,39,203,156,176,61,
                               124,147,196,160,239,135,17,77,127,12,3,19,222,46,
                               41,151,139,254,80,192,107,55,193,32,24,236,35,
                               175,93,16,179,98,87,169,254,191,134,3,51,184,119,
                               224,9,58,145,11,177,70,230,120,206,53,252,50,12,
                               3,151,220,18,103,3,70,10,195,168,141,111,136,166,
                               230,153,125,120,127,23,121,126,20,180,75,19,7,49,
                               127,48,182,170,27,231,133,168,210,126,214,129,22,
                               31,158,75,152,173,239,191,254,195,121,87,253,255,
                               230,176,15,223,159,116,190,28,208,31,254,207,226,
                               185,157,143,156,19,255,14,99,128,202,181,255,223,
                               122,78,98,237,30,69,120,203,147,112,238,8,50,48,
                               72,22,122,62,255,191,233,127,158,95,94,26,92,58,
                               86,9,36,114,158,127,91,207,183,227,99,125,160,
                               161,178,64,34,110,70,143,206,79,222,155,255,136,
                               248,151,149,6,58,116,83,68,41,63,36,112,140,110,
                               228,219,74,245,167,51,7,239,140,162,246,12,36,14,
                               167,209,81,109,102,8,5,185,44,164,59,128,221,152,
                               188,23,94,151,50,187,234,231,79,173,226,78,188,
                               195,108,225,120,218,188,42,55,8,103,196,48,30,
                               177,199,70,166,167,54,61,164,6,44,134,164,165,
                               152,53,193,126,197,214,137,151,137,129,40,99,53,
                               208,35,44,16,82,159,24,208,214,217,190,95,163,
                               142,28,68,200,170,59,170,227,186,237,18,8,190,40,
                               199,142,111,83,45,204,68,16,79,206,124,86,70,72,
                               24,26,26,234,203,143,133,30,7,193,12,16,74,175,
                               241,88,49,213,160,216,123,249,234,247,188,48,97,
                               220,37,184,202,211,182,213,43,117,29,94,96,61,
                               113,194,178,170,179,69,199,47,135,92,4,63,227,53,
                               218,111,174,106,247,109,68,234,186,173,68,95,170,
                               39,118,90,124,59,154,191,255,167,130,79,73,114,
                               157,104,155,131,104,137,248,123,0,153,175,147,
                               218,255,233,163,159,20,24,82,196,122,86,81,227,
                               19,122,120,114,195,58,111,109,26,233,233,234,53,
                               12,4,122,219,222,107,155,59,35,254,8,8,148,99,79,
                               108,59,187,123,220,17,6,168,153,222,222,115,75,
                               151,86,29,148,124,56,7,183,122,123,47,131,115,86,
                               125,170,49,163,104,236,79,67,195,184,163,255,234,
                               159,58,26,132,107,81,50,223,248,86,221,247,120,
                               211,24,53,221,193,160,197,145,24,226,223,248,102,
                               239,93,29,206,95,60,107,28,197,98,209,201,247,
                               225,200,170,165,31,240,170,98,181,100,172,212,71,
                               135,64,168,120,202,77,85,9,45,74,253,201,245,202,
                               23,190,180,158,9,174,66,123,111,192,158,242,105,
                               10,239,110,143,195,39,136,43,28,39,112,134,117,
                               77,191,140,116,252,129,0,220,127,88,248,39,26,
                               228,101,113,31,90,25,235,112,237,71,254,120,146,
                               67,189,149,108,173,185,127,140,158,73,237,57,118,
                               125,132,242,155,253,219,251,23,14,168,100,137,
                               179,251,123,165,224,176,209,146,181,16,48,25,177,
                               204,196,107,254,26,238,224,103,152,37,224,148,
                               130,149,81,139,103,240,235,181,251,183,239,240,
                               227,178,237,203,124,58,72,3,27,119,203,181,213,
                               63,249,182,43,103,15,0,86,183,232,191,62,29,72,
                               17,59,121,95,189,191,158,52,124,29,214,101,219,
                               119,225,219,1,9,191,89,81,161,101,217,122,107,
                               160,192,207,12,117,170,116,64,101,61,17,194,53,
                               43,229,26,158,245,67,121,113,170,154,47,198,51,
                               88,208,48,24,80,187,147,122,107,120,27,195,15,
                               208,158,53,19,103,201,91,171,70,22,92,255,18,217,
                               253,86,102,179,18,24,228,134,33,67,45,51,6,165,
                               172,173,24,77,155,109,55,144,212,178,13,203,99,
                               176,135,77,241,219,134,245,225,42,100,182,79,187,
                               195,80,36,117,145,230,139,246,61,234,93,33,144,
                               241,119,177,4,137,27,59,22,129,90,63,165,97,58,
                               69,32,161,87,11,188,204,27,115,176,134,226,80,47,
                               212,19,50,103,157,5,91,24,43,205,71,123,96,229,
                               66,37,135,219,141,86,114,169,73,116,193,233,7,
                               156,114,68,184,200,82,18,37,21,153,155,36,111,63,
                               119,52,95,205,42,200,125,24,80,238,8,81,229,187,
                               160,84,67,221,78,145,246,27,187,179,252,49,201,9,
                               194,240,212,168,14,98,70,113,171,26,152,190,31,
                               106,33,220,62,130,99,249,232,214>>.
wirecast_sr1() -> <<128,200,0,6,0,5,109,113,209,42,13,22,155,119,111,188,0,5,41,205,0,0,0,88,
  0,1,126,194,129,202,0,5,0,5,109,113,1,11,81,84,83,32,53,49,49,48,51,56,49>>.

wirecast_sr2() -> <<128,200,0,6,0,70,87,111,209,42,13,22,152,254,225,253,0,13,240,18,0,0,4,105,
                  0,16,221,37,129,202,0,5,0,70,87,111,1,11,81,84,83,32,53,49,49,48,51,56,49>>.

wirecast_audio_rtp() ->
<<128,224,68,171,0,5,25,205,0,5,109,113,0,48,11,
160,11,152,11,160,33,0,3,64,104,27,255,192,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,55,167,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,112,33,0,3,64,104,27,255,192,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,55,167,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,112,33,0,3,64,104,27,255,192,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,55,167,128,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,112>>.






  