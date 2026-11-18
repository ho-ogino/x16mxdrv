x16mxdrv (beta) - MDX music for the Commander X16
=================================================

Files
  X16MXDRV.BIN  the MDX sound driver
  MDXPLAY.PRG   the music player
  KANJI8.BIN    the player's 8x8 kanji font for song titles (made from the Misaki font)
  LICENSE.TXT   the license of X16MXDRV and mdxplay (MIT)
  MISAKI.TXT    the Misaki font's documentation and license

Using the player
  1. Copy X16MXDRV.BIN, MDXPLAY.PRG and KANJI8.BIN into one folder on the SD card.
  2. Put MDX files there or in folders below it. Keep each song's PDX (and P16 pack, if
     any) in the same folder as the MDX.
  3. On the X16, from that folder: LOAD "MDXPLAY.PRG",8 and RUN.

  Up / Down        select            Return      play the MDX / open the folder
  Left / Right     page up / down    Del         parent folder
  Space / F        stop / fade out   N / P       next / previous song
  A / R / S        auto-next / repeat / shuffle on or off
  < / >            loop count before the fade out
  1-8              mute FM channel 1-8
  Shift + 1-8      mute PCM channel P-W (Ctrl works too)
  9 / 0 / -        all channels on / off / flip
  Q                quit

Requirements
  A recent ROM (R48 recommended, R43 or later). PCM needs more than 512 KB of RAM
  (2 MB recommended); with 512 KB, songs play with FM only. MDX files up to 64 KB.

X16MXDRV is an unofficial, independent reimplementation of the behaviour of MXDRV
2.06+17 for the X68000. It is not affiliated with the authors of MXDRV.
The source code, the API for using the driver in your own programs and the P16 pack
tool are in the source repository (README.md, docs/api.md).


x16mxdrv(ベータ版)- Commander X16 で MDX を鳴らす
==================================================

ファイル
  X16MXDRV.BIN  MDX のドライバ
  MDXPLAY.PRG   音楽プレイヤー
  KANJI8.BIN    曲のタイトル用の 8×8 の漢字フォント(美咲フォントから作成)
  LICENSE.TXT   X16MXDRV と mdxplay のライセンス(MIT)
  MISAKI.TXT    美咲フォントの説明とライセンス

使い方
  1. X16MXDRV.BIN、MDXPLAY.PRG、KANJI8.BIN を、SD カードの同じフォルダに置きます。
  2. MDX は、そのフォルダかその下のフォルダに置きます。PDX(と P16 パック)は、その曲の
     MDX と同じフォルダに置いてください。
  3. X16 で、そのフォルダから LOAD "MDXPLAY.PRG",8 と RUN を実行します。
  キー操作は上の英語の表のとおりです。

動作環境
  新しい ROM(R48 を推奨、R43 以降)。PCM には 512KB より多い RAM が要ります(2MB を推奨)。
  512KB では FM だけで鳴らします。MDX は 64KB まで。

X16MXDRV は、X68000 の MXDRV 2.06+17 の動作を書き直した、非公式の独自実装です。
MXDRV の作者の方々とは関係がありません。ソース、自分のプログラムからドライバを使うための
API、P16 パックを作る道具は、ソースのリポジトリにあります(README.ja.md、docs/api.ja.md)。
