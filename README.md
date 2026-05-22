# 2026_1_BICproject

# 0517_MLP_pos_value 모듈 및 IP 역할 정리

## 1. 전체 구조

이 프로젝트는 마이크 입력을 받아 오디오 특징을 추출하고, MLP 기반 AI 모델로 사이렌 여부를 판단한 뒤, ANC 동작을 제어하는 구조다.

전체 흐름은 다음과 같다.

```text
MIC 입력
  -> I2S_MIC
  -> Feature
  -> AI_Calculate
  -> TOP_PathB에서 ANC 제어
  -> I2S_DAC
  -> DAC/스피커 출력
```

사이렌이 감지되지 않을 때는 ANC 모드에서 반전 오디오를 출력하고, 사이렌이 감지되면 약 1초 동안 ANC를 끄고 원래 소리를 출력한다.

## 2. TOP_PathB.v

프로젝트의 최상위 모듈이다.

주요 역할은 다음과 같다.

- 보드의 외부 입출력 포트를 전체 설계와 연결한다.
- `clk_wiz_0`에서 만든 6.144 MHz clock을 받아 내부 동작 clock으로 사용한다.
- 6.144 MHz clock을 나누어 I2S용 3.072 MHz clock을 만든다.
- `I2S_MIC`, `Feature`, `AI_Calculate`, `I2S_DAC` 모듈을 연결한다.
- 버튼 입력 `BTN_ANC`를 debounce 처리해서 ANC ON/OFF 상태를 토글한다.
- AI의 `siren_detected` 결과를 받아 사이렌 감지 상태를 유지한다.
- 사이렌 감지 시 약 1초 동안 ANC를 OFF하고 원래 오디오를 출력한다.
- LED 상태를 출력한다.
  - `LED[0]`: ANC 모드 ON/OFF 표시
  - `LED[1]`: 사이렌 감지 후 ANC 차단 상태 표시
- UART 로그 기능은 제거되었고, `UART_TX`는 idle 상태인 `1'b1`로 고정되어 있다.

## 3. I2S_MIC.v

I2S 마이크 입력을 받는 모듈이다.

주요 역할은 다음과 같다.

- 외부 I2S 마이크의 serial data를 수신한다.
- left/right 오디오 데이터를 병렬 24-bit 데이터로 변환한다.
- 샘플 하나가 준비될 때 `DATA_DONE` 신호를 발생시킨다.
- `TOP_PathB.v`는 이 `DATA_DONE` 신호를 기준으로 feature 추출용 sample valid 신호를 만든다.

현재 검증된 코드로 취급하며, 최종 수정 과정에서 변경하지 않았다.

## 4. Feature.v

마이크 오디오에서 AI 입력 feature를 만드는 모듈이다.

주요 역할은 다음과 같다.

- 마이크 입력 샘플을 받아 frame 단위로 처리한다.
- FFT 입력 데이터를 만들고 `xfft_0` IP에 전달한다.
- FFT 결과를 이용해 band energy 같은 주파수 특징을 계산한다.
- time-domain 특징도 함께 계산한다.
  - 예: 평균적인 크기, zero-crossing 관련 특징 등
- 이전 frame들의 특징과 현재 frame 특징을 묶어 MLP 입력 feature로 구성한다.
- feature memory write 신호를 통해 `AI_Calculate.v`에 입력 feature를 전달한다.
- 한 frame의 feature 준비가 끝나면 `MLP_START` 신호로 AI 계산을 시작시킨다.

## 5. AI_Calculate.v

MLP 기반 사이렌 판단을 수행하는 AI 계산 모듈이다.

주요 역할은 다음과 같다.

- `Feature.v`가 전달한 8-bit feature들을 내부 입력 메모리에 저장한다.
- BRAM IP에 저장된 weight와 bias를 읽어 MLP 연산을 수행한다.
- 현재 구조는 3개 layer로 구성되어 있다.
  - Layer 1: `W1_weight`, `W1_bias`
  - Layer 2: `W2_weight`, `W2_bias`
  - Layer 3: `W3_weight`, `W3_bias`
- 중간 layer는 requantization과 ReLU를 거쳐 다음 layer 입력으로 사용된다.
- 마지막 layer 결과를 `final_logit`으로 출력한다.
- `final_logit`이 `THRESHOLD_SCORE` 이상이면 사이렌으로 판단한다.
- 현재 주요 설정값은 다음과 같다.

```verilog
THRESHOLD_SCORE = 48'sd0
CONSECUTIVE_NEED_COUNT = 4'd1
```

즉 최종 logit이 0 이상이면 사이렌 감지 조건을 만족하고, 연속 1회 감지만으로 `siren_detected`가 1이 된다.

## 6. I2S_DAC.v

DAC로 I2S 오디오 출력을 내보내는 모듈이다.

주요 역할은 다음과 같다.

- `TOP_PathB.v`에서 선택된 left/right 오디오 데이터를 입력받는다.
- 병렬 24-bit 오디오 데이터를 I2S serial data로 변환한다.
- DAC용 `LRCK`, `DIN` 신호를 출력한다.
- `DAC_BCLK`는 `TOP_PathB.v`에서 생성한 clock을 사용한다.

현재 검증된 코드로 취급하며, 최종 수정 과정에서 변경하지 않았다.

## 7. clk_wiz_0 IP

Clock Wizard IP다.

주요 역할은 다음과 같다.

- Cmod A7 보드의 12 MHz `SYSCLK`를 입력으로 받는다.
- 내부 처리에 사용할 6.144 MHz clock을 생성한다.
- clock 안정화 상태를 `locked` 신호로 출력한다.
- `TOP_PathB.v`에서는 `locked`와 reset 버튼을 이용해 내부 reset 신호 `rstn`을 만든다.

## 8. xfft_0 IP

Xilinx FFT IP다.

주요 역할은 다음과 같다.

- `Feature.v`에서 전달한 time-domain 오디오 샘플을 FFT 처리한다.
- FFT 결과의 real/imag 값을 출력한다.
- `Feature.v`는 이 결과를 이용해 주파수 band energy feature를 계산한다.

## 9. BRAM IP들

MLP의 weight와 bias를 저장하는 ROM 역할의 Block Memory Generator IP들이다.

각 IP의 역할은 다음과 같다.

- `W1_weight`: 첫 번째 layer weight 저장
- `W1_bias`: 첫 번째 layer bias 저장
- `W2_weight`: 두 번째 layer weight 저장
- `W2_bias`: 두 번째 layer bias 저장
- `W3_weight`: 마지막 layer weight 저장
- `W3_bias`: 마지막 layer bias 저장

각 BRAM은 COE 파일을 통해 초기값이 들어가며, `AI_Calculate.v`가 주소를 넣어 필요한 weight/bias 값을 읽어온다.

## 10. XDC 제약 파일

보드의 실제 핀과 top-level 포트를 연결하는 제약 파일이다.

주요 역할은 다음과 같다.

- `SYSCLK`, `BTN`, `BTN_ANC`, `LED`, `MIC`, `DAC`, `UART_TX` 포트의 FPGA 핀 번호를 지정한다.
- 각 포트의 I/O standard를 `LVCMOS33`으로 설정한다.
- 12 MHz 시스템 clock 제약을 설정한다.

최종 bitstream 생성을 위해 반드시 프로젝트에 포함되어야 한다.

## 11. 최종 동작 요약

최종 버전의 핵심 동작은 다음과 같다.

```text
1. 마이크에서 오디오 입력을 받는다.
2. Feature.v가 FFT와 time-domain feature를 계산한다.
3. AI_Calculate.v가 MLP 연산으로 사이렌 여부를 판단한다.
4. 사이렌이 감지되지 않으면 ANC 모드에서 반전 오디오를 출력한다.
5. 사이렌이 감지되면 약 1초 동안 원래 오디오를 출력해 ANC를 끈다.
6. 1초 후 사이렌이 다시 감지되지 않으면 ANC 모드로 복귀한다.
```

