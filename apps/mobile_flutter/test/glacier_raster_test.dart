import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/widgets/hub21_material.dart';
import 'package:kasvault_wallet/src/services/glacier_glaze_cache.dart';

// The original Glacier veil recipe, rendered once into transparent textures.
// No wallet content, borders, text or controls are baked into these images.
void paintVeils(Canvas canvas, Rect rect) {
  final blur = ui.MaskFilter.blur(ui.BlurStyle.normal, math.max(8, rect.shortestSide * .10));
  canvas.drawOval(Rect.fromCenter(center: Offset(rect.left + rect.width * .24, rect.top), width: rect.width * 1.05, height: rect.height * .76),
    Paint()..maskFilter=blur..shader=const RadialGradient(colors:[Color(0x8A8CF7E8),Color(0x398CF7E8),Color(0x008CF7E8)],stops:[0,.45,1]).createShader(rect));
  canvas.drawOval(Rect.fromCenter(center: Offset(rect.right - rect.width * .16, rect.bottom), width:rect.width * 1.05,height:rect.height * .88),
    Paint()..maskFilter=blur..shader=const RadialGradient(colors:[Color(0x78C4A8FF),Color(0x36C4A8FF),Color(0x00C4A8FF)],stops:[0,.48,1]).createShader(rect));
  final ribbon=Path()..moveTo(rect.left-rect.width*.08,rect.top+rect.height*.72)..cubicTo(rect.left+rect.width*.22,rect.top+rect.height*.38,rect.left+rect.width*.62,rect.top+rect.height*.78,rect.right+rect.width*.08,rect.top+rect.height*.24);
  canvas.drawPath(ribbon,Paint()..style=PaintingStyle.stroke..strokeCap=StrokeCap.round..strokeWidth=math.max(12,rect.height*.18)..maskFilter=const ui.MaskFilter.blur(ui.BlurStyle.normal,13)..shader=const LinearGradient(colors:[Color(0x0077F7E9),Color(0x6E77F7E9),Color(0x5BBE9FFF),Color(0x00FFFFFF)]).createShader(rect));
}

void main() {
  testWidgets('export deterministic Glacier veil textures', (tester) async {
    if(Platform.environment['GLACIER_EXPORT']!='1') return;
    final output=Platform.environment['LOCKSCREEN_PREVIEW_DIR']!;
    await tester.runAsync(() async {
      for(final spec in [('square',384,384,80.0,80.0),('card',640,384,336.0,180.0),('wide',768,128,336.0,56.0)]) {
        final recorder=ui.PictureRecorder(),canvas=Canvas(recorder);
        canvas.scale(spec.$2/spec.$4,spec.$3/spec.$5);
        paintVeils(canvas,Rect.fromLTWH(0,0,spec.$4,spec.$5));
        final picture=recorder.endRecording(),image=await picture.toImage(spec.$2,spec.$3);
        final png=await image.toByteData(format:ui.ImageByteFormat.png);
        await File('$output/glaze-${spec.$1}.png').writeAsBytes(png!.buffer.asUint8List());
        image.dispose();picture.dispose();
      }
    });
  });

  testWidgets('Glacier cold-panel software raster profile', (tester) async {
    final output=Platform.environment['LOCKSCREEN_PREVIEW_DIR'];
    if(output==null)return;
    final stage=Platform.environment['GLACIER_STAGE']??'after';
    // Resolve new assets ahead of measuring; the released theme preloads these
    // once before it becomes visible. This is not a physical-device FPS test.
    await tester.pumpWidget(const MaterialApp(home:Scaffold()));
    await tester.runAsync(()async{
      if(stage!='before') {await GlacierGlazeCache.instance.ensure();expect(GlacierGlazeCache.instance.ready,isTrue);}
    });
    final samples=<int>[];
    await tester.runAsync(() async {
      for(var frame=0;frame<13;frame++) {
        final clock=Stopwatch()..start(),recorder=ui.PictureRecorder(),canvas=Canvas(recorder);
        canvas.scale(2);canvas.translate(0,-(frame%3).toDouble());
        final rects=<Rect>[const Rect.fromLTWH(12,12,336,170),for(var i=0;i<8;i++)Rect.fromLTWH(12+(i%4)*86,194+(i~/4)*88,78,78),for(var i=0;i<3;i++)Rect.fromLTWH(12,380+i*110,336,96),const Rect.fromLTWH(12,720,336,48)];
        final painters=<BoxPainter>[];
        for(final rect in rects){final p=GlacierGlassDecoration(radius:rect.height<50?999:20).createBoxPainter((){});painters.add(p);p.paint(canvas,rect.topLeft,ImageConfiguration(bundle:rootBundle,devicePixelRatio:1,size:rect.size));}
        final picture=recorder.endRecording(),image=await picture.toImage(720,1600);
        await image.toByteData();clock.stop();
        if(frame>=3)samples.add(clock.elapsedMicroseconds);
        if(frame==12){final bytes=await image.toByteData(format:ui.ImageByteFormat.png);await File('$output/glacier-surfaces-$stage.png').writeAsBytes(bytes!.buffer.asUint8List());}
        image.dispose();picture.dispose();for(final p in painters)p.dispose();
      }
      final sorted=[...samples]..sort();
      final report={'stage':stage,'softwareRasterOnly':true,'coldPanelsPerFrame':13,'pixels':[720,1600],'samplesUs':samples,'medianUs':sorted[sorted.length~/2]};
      await File('$output/glacier-raster-$stage.json').writeAsString(jsonEncode(report));
      print('Glacier software raster: $report');
    });
    expect(tester.takeException(),isNull);
  });
}
